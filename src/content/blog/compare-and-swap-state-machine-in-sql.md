---
title: "CHECK constraints guard states, not transitions"
description: "A CHECK constraint can't stop a finished CI run from going back to queued, because it only sees the new row. A conditional UPDATE can. Here's the compare-and-swap pattern in Postgres, the read-then-write version that let 19 of 20 goroutines win, and two type errors along the way."
pubDate: 2026-12-02
tags: ['PostgreSQL', 'Go', 'Architecture']
draft: true
---

Every run in my CI service moves through a small state machine:

```
queued ──► running ──► succeeded | failed | timed_out
   │          │
   └──────────┴──────► cancelled
running ──► queued      (the reaper requeues a run whose worker died)
```

I wanted the database to enforce it, not just the Go code. Plenty of things
will change a run's status concurrently: workers finishing, users cancelling,
a reaper requeuing. The obvious tool was a CHECK constraint, and it turned out
to be the wrong one.

## What CHECK can and can't see

The `runs` table already has CHECK constraints that tie the timestamps to the
status. For example, `finished_at` is set if and only if the status is
terminal. They work well. Then I tried two updates that the state machine
forbids:

```sql
UPDATE runs SET status = 'queued', finished_at = NULL WHERE id = :r1;  -- succeeded → queued
UPDATE runs SET status = 'failed' WHERE id = :r1;                      -- succeeded → failed
```

Both went through. **A CHECK constraint sees only the new version of the row,
not the old one.** "Queued, with no `finished_at`" is a perfectly valid row,
and the constraint has no way of knowing it was `succeeded` a moment ago. So
CHECK constraints guard *states*, and they can't guard *transitions*.

A trigger with access to `OLD.status` could do it. But there's a simpler way,
and it also solves concurrency.

## Put the expected state in the `WHERE`

```sql
UPDATE runs SET status = $3::text, ...
WHERE id = $1 AND status = $2::text
```

The caller says "I think this run is in `from`; move it to `to`." One updated
row means the transition happened. Zero rows means either there's no such
run, or it isn't in `from` anymore because someone else changed it first.

This is compare-and-swap, done in SQL. The Go side looks like this:

```go
// Transition moves the run with the given ID from status from to status
// to, if it's still in from.
Transition(ctx context.Context, id string, from, to Status) error
```

**`from` is supplied by the caller on purpose.** A method that took only `to`
would have to read the current status itself, which looks tidier but just
hides the race inside the method. A cancel and a completion would both read
`running`, and both would "succeed."

It returns three errors, and each one means something different:

- **`ErrInvalidTransition`**: the graph has no such edge, for example
  `succeeded → queued`. That's a bug in the caller, and it's checked *before*
  going to the database, so a missing run can't hide it.
- **`ErrNotFound`**: no such run.
- **`ErrStatusConflict`**: the edge is valid, but the run isn't in `from`
  anymore. Someone else won. That's the normal outcome of a race, not a bug,
  and the API will turn it into a `409`.

After zero rows, one extra `SELECT status` tells `ErrNotFound` apart from
`ErrStatusConflict` and puts the current status into the error message. That
read may already be out of date, but it doesn't matter: our `UPDATE` changed
nothing either way.

## Why the conditional `UPDATE` is atomic

Say two transactions run the `UPDATE` on the same row at the same moment: one
moving `running → succeeded`, the other `running → cancelled`.

1. The first one locks the row and updates it.
2. The second one blocks on the row lock.
3. The first one commits. The second one now **re-evaluates its `WHERE`
   against the new version of the row**. In Postgres's `READ COMMITTED` mode
   this is called EvalPlanQual. It sees `succeeded`, not `running`, and
   updates nothing.

No `SELECT ... FOR UPDATE` and no explicit locking. The check is the `WHERE`
clause, and the row lock serializes the rest.

## The version that looks right

To check that the tests would actually catch a race, I replaced the
conditional `UPDATE` with the obvious alternative: read the status, check it
in Go, then write.

```go
var current Status
db.QueryRow(ctx, "SELECT status FROM runs WHERE id = $1", id).Scan(&current)
if current != from {
	return ErrStatusConflict
}
db.Exec(ctx, "UPDATE runs SET status = $2 WHERE id = $1", id, to)
```

The concurrent test puts one run in `running` and starts 20 goroutines that
all try to move it to a terminal status (`succeeded`, `failed`, `cancelled`,
`timed_out`). Exactly one should win. With read-then-write, the test failed
3 times out of 3, and **up to 19 of the 20 goroutines "won."** They all read
`running` before any of them wrote.

The same rule applies to the in-memory store used in unit tests: the status
check and the write happen under one `mu.Lock()`. Checking under one lock and
writing under another is the same race.

## Timestamps go in the same statement

A transition changes more than the status. The same `UPDATE` sets
`started_at` when the run enters `running`, clears it when the run is
requeued, sets `finished_at` when it enters a terminal status, and increments
`attempt` on `running → queued`:

```sql
UPDATE runs
SET status      = $3::text,
    started_at  = CASE $3::text WHEN 'running' THEN now()
                                WHEN 'queued'  THEN NULL
                                ELSE started_at END,
    finished_at = CASE WHEN $4::bool THEN now() END,
    attempt     = CASE WHEN $2::text = 'running' AND $3::text = 'queued'
                       THEN attempt + 1 ELSE attempt END
WHERE id = $1 AND status = $2::text
```

This is where the CHECK constraints come back. They can't police transitions,
but they **check that each transition leaves a valid row**. A test walks every
edge of the graph, and a mistake in one of these `CASE` expressions fails
immediately with `23514` (`check_violation`). When I broke `finished_at` on
purpose so it was never set, that test failed on `runs_finished_at_iff_terminal`.

So each layer does its own job: **the schema guarantees every row is valid,
and the conditional `UPDATE` guarantees every transition is allowed.**

## Two type errors on the way

**One parameter, two types.** Without the `::text` casts, Postgres refuses to
prepare the statement:

```
ERROR:  inconsistent types deduced for parameter $3
DETAIL:  text versus run_status
```

`status` is a domain type (`run_status`), so `SET status = $3` infers `$3` as
`run_status`. `CASE $3 WHEN 'running'` infers it as `text`. Casting to `::text`
everywhere fixes it. In `SET`, the assignment cast from `text` to `run_status`
still applies, so the domain's own CHECK is still enforced.

**`CASE ... THEN NULL` is `text`.** A `CASE` whose only branch is an untyped
`NULL` gets the type `text`:

```
ERROR:  column "finished_at" is of type timestamp with time zone
        but expression is of type text
```

I first ran into it while breaking the code on purpose. I expected a CHECK
violation and got `42804` instead. The fix is `NULL::timestamptz`, or a branch
with a real type like `now()`.

## The graph is checked twice

The allowed transitions live in a Go `map[Status][]Status`, and
`CanTransition` reads it. The test checks all 36 `from → to` pairs against a
table that's **typed out again inside the test**, copied from the lifecycle
document rather than built from the map. If the test read the same map, a
typo in the map would show up in the test too, and the test would pass.
