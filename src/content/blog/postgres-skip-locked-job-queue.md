---
title: "A Postgres job queue in one statement, and what breaks when you remove each part"
description: "UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) is the standard Postgres job queue. I removed its parts one at a time: duplicate claims, workers that think the queue is empty, and a queue that runs in single file."
pubDate: 2026-11-18
tags: ['PostgreSQL', 'Go', 'Distributed Systems']
---

The CI service I'm building stores its runs in Postgres, and workers take
queued runs from the same table. I didn't want to add a separate broker for
that. Postgres can do it with one statement, which is a well-known pattern.

I used the pattern, and then I removed its parts one at a time to see what
each one does. Each removal fails in a different way, and one of them hides
the bug instead of fixing it.

## The claim

```sql
UPDATE runs
SET status           = 'running',
    started_at       = now(),
    lease_expires_at = now() + $1::bigint * interval '1 microsecond'
WHERE id = (
    SELECT id FROM runs
    WHERE status = 'queued'
    ORDER BY created_at, id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING id, repo, commit_sha, status, created_at, lease_expires_at
```

The subquery finds the oldest queued run, and the `UPDATE` moves it to
`running` with a lease. The whole claim is one statement, so it's one
transaction. If the worker crashes halfway through, the run simply stays
`queued`.

A few details are there on purpose:

- **`ORDER BY created_at, id`.** Without a second key, runs with the same
  `created_at` come back in no defined order. The IDs are UUIDv7, which grow
  over time, so the tiebreaker is also a fair FIFO.
- **The lease comes from the database clock** (`now() + d`). The reaper that
  will later look for expired leases also compares against the database clock,
  so the application's clock never has to agree with it.
- **Microseconds, not nanoseconds.** Postgres's `interval` can't store
  nanoseconds, so the Go side passes `d.Microseconds()`.
- **An empty queue isn't an error.** No row means `(Lease{}, false, nil)`. That's
  the normal case, and the dispatcher just waits and tries again.

## The experiment

To see what each part does, I ran four versions of the claim against the same
setup: 200 queued jobs, 8 workers, and each worker claiming in a loop until it
gets no row back. After each run I counted how many jobs were claimed more
than once, and how many workers stopped while jobs were still queued.

| Variant | Jobs claimed more than once | Workers that quit early | Time |
|---|---|---|---|
| `FOR UPDATE SKIP LOCKED` | 0 | 0 | 77 ms |
| `FOR UPDATE` | 0 | 0 | 70 ms |
| No lock | **157 of 200** (up to 8 times) | 0 | 160 ms |
| No lock + `AND status = 'queued'` outside | 0 | **7 of 8** | 620 ms |

I repeated each variant three times, and the numbers barely moved.

### Without a lock, every worker claims the same job

Remove `FOR UPDATE SKIP LOCKED` and 157 of 200 jobs were claimed by more than
one worker. One job was claimed by all eight.

That surprised me at first, because an `UPDATE` does lock the row it changes.
The catch is *when* the row is chosen. The subquery runs first, without a lock,
and several workers read the same oldest `id` at the same moment. Then their
`UPDATE`s queue up on that row. When the first one commits, the next one
re-checks its `WHERE` clause against the new version of the row. In Postgres
that's called EvalPlanQual. But the only condition left in the outer `WHERE`
is `id = <the id I picked>`, which is still true. So the second worker updates
the row too, and both now think they own the job.

### The fix that hides the bug

The obvious patch is to also check the status in the outer `WHERE`:

```sql
WHERE id = (SELECT ...) AND status = 'queued'
```

This gets rid of the duplicates. The re-check now sees `running` and the
second worker updates nothing. But that worker gets **zero rows back**, and
zero rows means "the queue is empty." In my run, 7 of the 8 workers gave up
while jobs were still waiting. A single worker drained the rest of the queue
on its own, about eight times slower.

In a real dispatcher the loser wouldn't exit. It would sleep for its poll
interval and try again. So nothing would look broken. Workers would just sit
idle while there's work to do, and throughput would quietly drop to roughly
one worker's worth.

### `FOR UPDATE` alone is correct, but forms a line

With `FOR UPDATE` and no `SKIP LOCKED`, the first worker locks the oldest
row. Every other worker that picked the same row **waits** for that lock.
After the commit, they re-check `status = 'queued'` (it's part of the
subquery now), drop the row, and move on to the next one.

That's correct, and in my first run it was no slower (70 ms). The claim is a
single statement, so each lock is held for microseconds. To see the cost, I
kept the claiming transaction open for 10 ms after the `UPDATE`. That's what
happens when a claim does a bit of extra work in the same transaction:

| Claim transaction held 10 ms | Time for 200 jobs |
|---|---|
| `FOR UPDATE SKIP LOCKED` | 0.40 s |
| `FOR UPDATE` | 2.75 s |

2.75 seconds is about 200 × 13 ms. The eight workers are processing the queue
one at a time. `SKIP LOCKED` tells them not to wait on a locked row and to
take the next one, so they actually run in parallel.

## Testing it: make the race likely

The project's test for this has 50 queued runs and 8 workers, each claiming
until the queue is empty. It asserts that every run was claimed by exactly one
worker. With `FOR UPDATE SKIP LOCKED` removed, it fails 5 times out of 5.

The first version of the test was weaker. It started 20 goroutines that each
made **one** claim, and it caught the duplicate only about one time in three.
The test's connection pool had 4 connections, so at most 4 claims reached the
database at once, and only at the very start. Having workers drain the queue
creates a race for every run instead of only the first one.

The test also passes with `FOR UPDATE` but no `SKIP LOCKED`, and it should.
Correctness is all the test checks, and that variant is correct. Its problem
is speed, which a correctness test can't measure.

## What this queue doesn't cover yet

- **A worker that dies.** Its run stays `running` until the lease expires. A
  separate reaper (not built yet) will move runs with expired leases back to
  `queued`. `Claim` never touches them.
- **Fencing.** A worker whose lease expired might still finish its run after
  the reaper has given it to another worker. A status check alone can't tell
  them apart, because the status is `running` again. The fix is a token, such
  as the attempt number, included in the condition that completes the run.

Both are planned, and they follow the same idea as the claim: let one
conditional statement in the database decide who wins, and don't read first
and write later.
