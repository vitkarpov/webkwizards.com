---
title: "A test that can't fail doesn't test anything"
description: "After every new test, I break the code it covers and check that the test notices. Here are eight examples from one Go project: tests that passed no matter what, a race caught one time in three, and a test that passed by accident on one backend but not the other."
pubDate: 2026-12-09
tags: ['Testing', 'Go']
---

There's one habit from building my CI service that I'd keep on any project.
**After writing a test, break the code it covers and watch the test fail.**
If it doesn't fail, the test is checking something other than what I think.

That's mutation testing done by hand. There are tools that automate it, but
picking the one mutation that *should* be caught tells you more than a
mutation score does. These are the cases from one project where it found
something.

## 1. 100% coverage, no concurrency

The first in-memory store had 100% test coverage. It also had a bug that
`go build` and `go vet` both missed:

```go
s.mu.RLock()
defer s.mu.Unlock() // should be RUnlock
```

The first `GET /runs/{id}` would have crashed the server with
`fatal error: sync: Unlock of unlocked RWMutex`. That's a fatal error, not a
panic, so `recover` can't catch it. A plain unit test does catch this one.
But a store with **no** mutex at all would have passed every test, because
every call came from a single goroutine.

Coverage tells you which lines ran. It doesn't tell you the code is correct.

So I added a test where 100 goroutines save and read at once, and then broke
the code by deleting every `Lock` and `Unlock`:

- **With `-race`:** `WARNING: DATA RACE`, failing on every run.
- **Without `-race`:** 4 of 5 runs failed with `concurrent map writes`, and
  **one passed**. The runtime only detects concurrent map writes when two of
  them actually overlap in time.

That's why `make test` always uses `-race`.

## 2. The concurrent test with no assertions

A code review then pointed out that this concurrent test didn't check
anything. It ignored errors and never verified that the 100 records were
still there afterwards. The race detector doesn't need assertions, so as a
race trap the test worked. But a store that lost writes would pass it.

After adding the assertions, I broke the store a different way: `Save` wrote
to the wrong map key (`r.ID+"x"`). The new test failed with
`GetByID("run-40") error = run not found`. The old one would have passed.

## 3. A counter that stopped counting

Some handler tests use a wrapper store that counts calls. That's how they
assert "a rejected request created nothing." Later the webhook handler moved
from `Create` to a new method, `CreateFromDelivery`. The wrapper only counted
`Create`.

Those tests went on passing, and from that point on they would have passed no
matter what the handler did. I found it only because I broke the handler and
the tests stayed green. The fix was one more counter, but nothing would have
pointed me to it.

## 4. A race test that caught the race one time in three

The job queue's claim query relies on `FOR UPDATE SKIP LOCKED`. When I removed
it, the first version of the concurrency test, 20 goroutines making one claim
each, caught the duplicate claim only **about one time in three**.

The test's connection pool had 4 connections. At most 4 claims reached the
database at once, and only at the very beginning. After that the goroutines
ran mostly one after another, so there was nothing to race.

The rewrite has 8 workers that each claim in a loop until 50 queued runs are
gone, so there's a race for every run, not just the first. It now fails 5
times out of 5 with the lock removed.

A flaky failure on broken code is a weak test. The question isn't only "can it
fail" but "does it fail every time."

## 5. A mutation that only one backend caught

Every store test runs against two implementations: an in-memory store and
Postgres. The dispatcher has a rule: if the run's lease has expired, don't
touch the run, because another worker may own it now. When I removed that
check:

- the **in-memory** run of the test failed, as it should;
- the **Postgres** run **passed**.

It passed by accident. With an expired context, the Postgres `Transition` call
failed before it even reached the database, so the run was left alone anyway.
The in-memory store doesn't look at the context, so it applied the update.

Running the same tests against two implementations is usually justified as
"keep the fake honest." Here it worked the other way: the fake caught a gap
that the real database happened to cover up.

## 6. A test that couldn't detect a slowdown

The dispatcher should claim the next run **right away** after finishing one,
and sleep for its poll interval only when the queue is empty. I added a pause
after every claim. No test failed.

The tests used a short poll interval, so the extra pauses didn't add up to a
failure. The fix was to set `Poll = time.Hour` in the test that processes a
full queue. Now the only way it can finish is by claiming runs back to back,
and the pause mutation fails it.

## 7. A mutation that should *not* fail

Removing `SKIP LOCKED` but keeping `FOR UPDATE` makes the queue **slower but
still correct**. Workers wait on a locked row instead of skipping it. The
concurrency test passes, and that's the right result: it tests correctness.
If it failed, it would be testing something it shouldn't.

Knowing what a test *shouldn't* catch is part of knowing what it does catch.
Speed needs its own measurement.

## 8. A skipped test looks like a passing one

The Postgres tests originally ran only when `DATABASE_URL` was set, and
called `t.Skip` otherwise. In normal `go test` output, a package whose tests
were all skipped still shows `ok`. It would be easy to go a month without
noticing that the Postgres tests never ran.

They now use a build tag instead. `make test` runs the unit tests with no
Docker needed. `make test-integration` adds `-tags integration`, starts
Postgres in a container, and **fails** if Docker isn't there. A command that
says it runs the integration tests shouldn't be able to skip them silently.

## What the eight cases have in common

None of these tests were sloppy. They looked right and they passed. The
problems only showed up when the code changed under them: a new method, a
different pool size, a different backend. Breaking the code on purpose is the
fastest way I know to see what a test actually depends on.

The habit itself costs a few minutes per test:

1. Write the test and see it pass.
2. Pick the mutation the test exists to catch: remove the lock, skip the
   check, write to the wrong key.
3. Run it. If it's a concurrency test, run it several times.
4. If the test still passes, the test is what needs fixing.
5. Undo the mutation.

Step 5 matters too.
