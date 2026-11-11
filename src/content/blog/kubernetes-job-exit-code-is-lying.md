---
title: "Your Kubernetes Job's exit code is lying to you"
description: "I made a Kubernetes Job fail three ways: a failing test, an OOM, and a deadline. All three ended as the same Failed, and two of them left no logs. Here's what I learned and how it shaped the result contract of a CI worker."
pubDate: 2026-11-11
tags: ['Kubernetes', 'CI', 'Architecture']
draft: true
---

I'm building a small CI system that runs checks on code written by AI agents.
Each check runs as a Kubernetes Job: clone a repository at a given commit, run
`go build`, `go vet` and `go test`, and report the result. At first the plan
seemed simple. The Job succeeds if the tests pass and fails if they don't, and
the control plane reads the outcome from the Job's status.

Before writing any control-plane code, I made a Job fail on purpose in three
different ways to see what the control plane would actually get back. That
plan didn't survive the experiment.

## The baseline Job

The Job clones [`google/uuid`](https://github.com/google/uuid) at a fixed
commit and runs its tests:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  generateName: go-test-
  namespace: agentic-ci-runs
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: check
          image: golang:1.27
          command: ["sh", "-euc"]
          args:
            - |
              git init -q /src && cd /src
              git fetch -q --depth 1 "$REPO" "$COMMIT"
              git checkout -q FETCH_HEAD
              go test ./...
          resources:
            limits:
              cpu: "1"
              memory: 1Gi
```

A few details here turned out to matter:

- **`git fetch` by SHA, not `git clone --branch`.** `--branch` only accepts a
  branch or tag, and a CI run needs the exact commit from the webhook.
  GitHub allows fetching by SHA.
- **`generateName` and `kubectl create`, not `apply`.** Each run needs its own
  Job, and a Job's `spec.template` can't be changed after creation, so a fixed
  `name` with `apply` would create nothing the second time.
- **`ttlSecondsAfterFinished`.** Without it, finished Jobs pile up forever.

In a local [kind](https://kind.sigs.k8s.io/) cluster this took 34 seconds,
about 15 of which went to pulling `golang:1.27` the first time.

## Three ways to fail

I made three variants of the Job:

| Variant | What I broke | Pod status | Exit code | Job condition |
|---|---|---|---|---|
| fail | Added a test that calls `t.Fatal`, `backoffLimit: 2` | `Error` ×3 | 1 | `Failed`, `BackoffLimitExceeded` |
| oom | `limits.memory: 64Mi` | `OOMKilled` | 137 | `Failed`, `BackoffLimitExceeded` |
| slow | `sleep 600`, `activeDeadlineSeconds: 15` | Pod deleted | — | `Failed`, `DeadlineExceeded` |

At the Job level, all three are just `Failed`. A failing test (a real problem
in the code) looks the same as an out-of-memory kill or a deadline (problems
with the environment). Any difference is either in the condition's `reason`
or deeper in the Pod status, and as it turned out, the Pod isn't always there
to inspect.

### A failing test is retried, slowly

With `backoffLimit: 2`, Kubernetes ran the failing test three times:

| Pod | Created | Finished |
|---|---|---|
| 1 | 11:59:27 | 11:59:43 |
| 2 | 11:59:53 (+10 s) | 12:00:08 |
| 3 | 12:00:28 (+20 s) | 12:00:43 |

`backoffLimit: 2` means **three** attempts: the first one plus two retries.
The delay between attempts doubles (10 s, 20 s, 40 s, up to 6 minutes). The
default `backoffLimit` is **6**, so a failing test would loop for about ten
minutes before the Job gave up. A failing test is a result, not a flaky
glitch, and rerunning it returns the same answer at the same cost. For CI
checks, set `backoffLimit: 0`.

There's also a smaller trap here. `kubectl logs job/<name>` with three Pods
prints:

```
Found 3 pods, using pod/go-test-fail-zmjlt-9vtll
```

That's whichever Pod it finds first, not necessarily the latest one. It's fine
for a person, but code that reads results has to pick the Pod itself.

### OOM leaves no logs at all

The 64 MiB container was killed within a second, while `git fetch` was still
running. Exit code 137 is 128 + 9, meaning the process received `SIGKILL`.
The only sign of what happened is `reason: OOMKilled` in
`status.containerStatuses[].state.terminated`. There was no output at all.
If you're reading the logs to decide what happened, an OOM looks like a check
that printed nothing.

### A deadline deletes the evidence

When `activeDeadlineSeconds` expires, the Job controller **deletes all of its
Pods**. After that, `kubectl logs` has nothing to return. It doesn't fail
quickly either. It hangs and then prints
`error: timed out waiting for the condition`.

The timing was also off. The deadline was at 11:59:42, but the Job became
`Failed` at 12:00:13, **31 seconds later**. That's the default
`terminationGracePeriodSeconds` of 30 seconds. The Pod received `SIGTERM`, but
the container's PID 1 was `sh`. Linux doesn't apply a signal's default action
to PID 1, so a PID 1 without a handler ignores `SIGTERM`. `sleep` kept running
until `SIGKILL` arrived 30 seconds later.
(I [ran into the same PID 1 behavior on ECS](/blog/sqs-messages-stranded-on-deploy/)
before.)

`activeDeadlineSeconds` also counts from the start of the Job and includes all
retries and the pauses between them, so it takes precedence over
`backoffLimit`.

## What this means for the design

Two conclusions came out of these experiments.

**The Pod's exit code is a poor channel for the result.** "The tests failed",
"the container ran out of memory", "it hit the deadline", and "the network was
down during clone" all end up as the same `Failed`. A CI system has to
distinguish *your code is broken* from *we couldn't check your code*. The first
is feedback for the author. The second is our problem, and a candidate for a
retry.

**Pod logs aren't storage.** They disappear with the Pod: after the TTL, at
the deadline, or when someone deletes the Job. If the result lives only in the
logs, you have to collect it before any of that happens, and in the deadline
case you might not get the chance.

## A worker that separates the verdict from the exit code

So instead of running a shell script in the Job, I wrote a small Go worker
with an explicit contract. The verdict goes into JSON on stdout, and the exit
code only says whether the check took place:

| Exit code | When | Job |
|---|---|---|
| 0 | The checks ran to completion, and the result is `passed` **or** `failed` | `Complete` |
| 1 | No verdict: a step errored or timed out | `Failed` |
| 2 | Bad arguments, no JSON | `Failed` |

A failing test now produces a `Complete` Job with `"status": "failed"` in the
JSON. **A Job that is `Failed` means the infrastructure broke, not the code.**

The JSON reports each step separately:

```json
{
  "commit": "0f11ee6918f41a04c201eceeadf612a377bc7fbc",
  "status": "passed",
  "duration_ms": 17595,
  "steps": [
    {"name": "checkout", "status": "passed", "exit_code": 0, "duration_ms": 725},
    {"name": "build", "status": "passed", "exit_code": 0, "duration_ms": 10943},
    {"name": "lint", "status": "passed", "exit_code": 0, "duration_ms": 2203},
    {"name": "test", "status": "passed", "exit_code": 0, "duration_ms": 3722,
     "output": "ok  \tgithub.com/google/uuid\t0.011s\n"}
  ]
}
```

Each step ends in one of five states: `passed`, `failed` (the check found a
problem in the code), `timed_out`, `error` (the step couldn't run, for example
the commit didn't download), and `skipped`. Only `failed` is a verdict about
the code. The overall status is chosen in this order: `timed_out` if any step
timed out, otherwise `error` if any step errored or was skipped, otherwise
`failed` if any step failed, otherwise `passed`.

**An incomplete check outranks a failed one.** If the build failed and the run
then hit its deadline before the tests finished, reporting just `failed` would
hide the fact that part of the code was never checked. (The worker keeps
running the later steps after a failed build, because their output can still
be useful.)

A few smaller decisions follow from the experiments:

- **A failed checkout is `error`, not `failed`.** Not being able to download a
  commit tells you nothing about the code.
- **The worker handles `SIGTERM` itself.** With a Job deadline of 8 seconds and a
  build that takes 11, the worker caught the signal, marked the build step as
  `error` with `"go: interrupted: terminated signal received"`, and wrote its
  JSON in the same second. The Job finished right at its deadline, without the
  30-second wait.
- **The worker's own timeout is shorter than Kubernetes'.** The worker runs
  with `-timeout=5m` and the Job with `activeDeadlineSeconds: 330`. The worker
  should hit its own deadline first and report a proper `timed_out`, rather
  than being killed and leaving nothing behind.
- **`terminationGracePeriodSeconds: 10`.** The worker needs a fraction of a
  second to shut down, so there's no reason to keep the Pod around for 30.

## What's still open

The worker's JSON still goes to stdout, so it's still in the Pod's logs, and
the deadline case still deletes it with the Pod. I only captured it in that
test because I had started `kubectl logs -f` beforehand. The next step is
getting the result out of the Pod reliably. The options are a termination
message (`/dev/termination-log`, which is limited to 4 KiB), a file on a
volume, or having the worker send the result to the control plane itself.

Whichever one I choose, the contract above stays the same: **the exit code
says whether the check ran, and the JSON says what it found.**

A gotcha to finish with: `kubectl wait --for=condition=complete` on a Job that
failed doesn't return early. It waits for the full timeout, because `Failed`
is a different condition. In scripts, wait with `--for=jsonpath` or check
`.status.conditions` in a loop.
