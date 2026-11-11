---
title: "Killing `go test` doesn't kill the tests"
description: "exec.CommandContext kills only the process it started. go test runs your tests in a child process, so a timeout either leaves orphans behind or hangs Wait, depending on how you call it. Here's what I measured and the four lines that fix it."
pubDate: 2026-11-25
tags: ['Go', 'Linux', 'CI']
draft: true
---

My CI worker runs `go build`, `go vet` and `go test` on code it didn't write.
Some of that code will hang, so every step runs under a deadline. The
straightforward way to do that in Go is `exec.CommandContext`. When the context
ends, the process gets killed:

```go
ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
defer cancel()
cmd := exec.CommandContext(ctx, "go", "test", "./...")
cmd.Stdout, cmd.Stderr = out, out
err := cmd.Run()
```

It looks finished. But "the process" means only `go`, and `go test` doesn't
run your tests itself.

## `go test` is a parent process

`go test` compiles each package into a test binary and runs that binary as a
**child process**. If a test starts its own processes, those are children of
the test binary. A hanging test ends up as a process tree:

```
go test ./...
└── target.test        (compiled test binary)
    └── sleep 3699     (started by the test)
```

`CommandContext` sends `SIGKILL` to `go` and nothing else. Killing a parent on
Unix doesn't kill its children. They're reparented and keep running.

## What actually happens

I tested it with a test that runs `sleep 3699` and waits for it, a 5-second
deadline, and output collected in a buffer (so through a pipe, which is what a
worker does). I tried three `go test` modes and three ways of killing:

| | `go test ./...` | `go test` (no package args) |
|---|---|---|
| Plain `CommandContext` | `Run` returns at 5 s; **test binary and `sleep` keep running** | **`Run` still blocked at 25 s**; both keep running |
| + `WaitDelay = 1s` | Returns at 5 s; both keep running | Returns at 6 s; both keep running |
| + kill the process group | Returns at 5 s; nothing left | Returns at 5 s; nothing left |

(`go test -v ./...` behaved like `./...`.)

Two different failures come from the same cause:

- **In package-list mode** (`./...`, a list of packages), `go` reads the test
  binary's output itself and passes it on. Our pipe is connected only to `go`.
  Kill `go` and the pipe closes, so `Run` returns on time. But the test binary
  and everything it started are now **orphans**. They keep using CPU and
  memory until they finish on their own. Here that would be when the test
  binary's default 10-minute `-test.timeout` ran out, and the `sleep` would
  outlive even that.
- **In local directory mode** (`go test` with no package arguments), the test
  binary writes straight to the stdout that `go` inherited, which is our pipe.
  Kill `go` and the test binary still holds the write end open. `Run` reads
  the pipe until EOF, and EOF only comes when **every** process holding the
  pipe has exited. So `Run` blocks until the hanging test finishes, which
  could be never.

So either the timeout doesn't stop the work, or the timeout doesn't return at
all. It depends on how the command is written, and that's easy to change
without noticing.

## The fix: a process group and `cmd.Cancel`

```go
cmd := exec.CommandContext(ctx, args[0], args[1:]...)
cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
cmd.Cancel = func() error {
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
cmd.WaitDelay = time.Second
```

- **`Setpgid: true`** puts the command in its own process group. Children
  inherit the group, so `go`, the test binary and anything the tests start
  all belong to it.
- **`syscall.Kill(-pid, ...)`** with a negative PID sends the signal to every
  process in the group, not just one.
- **`cmd.Cancel`** (Go 1.20+) replaces what `CommandContext` does when the
  context ends. The default is `cmd.Process.Kill()`, which signals only the
  parent.
- **`WaitDelay`** is the backstop. A process can leave the group (with
  `setsid`, for example) and keep the pipe open. `WaitDelay` limits how long
  `Wait` keeps waiting for the pipe to close after the kill. As the table
  shows, it **doesn't** kill anything. It only stops your code from waiting
  forever.

I send `SIGKILL` right away, not `SIGTERM` followed by a grace period. A
check has nothing to save, and the worker's own shutdown window is short.

The project's test for this runs a repository whose test hangs on
`sleep 3601`, with a 10-second deadline. It asserts three things: the step is
`timed_out`, `Run` returned within 11 seconds, and `pgrep` finds no
`sleep 3601` afterwards. The last assertion is the one that matters. It's the
only one that would catch the orphans.

## Telling a timeout from an interruption

Once killing works, the worker also needs to report *why* a step was killed. A
deadline means the code was too slow (`timed_out`). A `SIGTERM` from
Kubernetes means the check didn't get to finish (`error`). Both show up as
"the context ended," and `context.Cause` tells them apart:

```go
case errors.Is(context.Cause(ctx), context.DeadlineExceeded):
	st.Status = StatusTimedOut
case ctx.Err() != nil:
	st.Status = StatusError
	st.Error = fmt.Sprintf("%s: interrupted: %v", args[0], context.Cause(ctx))
```

With `signal.NotifyContext`, the cause includes the signal, so the result JSON
says `"go: interrupted: terminated signal received"` instead of a generic
`context canceled`.

## Does it matter inside a container?

Partly. When the worker is PID 1 in a Kubernetes Pod and exits, the container
ends and the kernel kills every process left in it. So orphans in a one-shot
Pod die soon after the worker finishes.

But that's luck, not design. Between the timeout and the exit, the orphans are
still using the CPU and memory limits the next steps need. And the same code
runs on my laptop, in its own tests, and possibly later in a long-running
runner. In those places nothing cleans up after it.

## A related trap: `defer` and return values

While writing this step runner, I made a smaller mistake. I filled in
`Output` and `DurationMS` in a `defer` so they'd be set on every return path:

```go
func runStep(...) Step {
	st := Step{...}
	defer func() { st.DurationMS = time.Since(start).Milliseconds() }()
	...
	return st
}
```

The tests showed empty output and 0 ms. `return st` copies the value **before**
deferred functions run, so the `defer` was changing a variable nobody read
anymore. A deferred function can only change what's returned if the result is
named:

```go
func runStep(...) (st Step) {
```
