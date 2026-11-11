---
title: "A missing `tx` didn't fail my test. It deadlocked my service"
description: "I broke a Postgres transaction on purpose and expected a red test. The test hung instead. One query that skipped the transaction made every pool connection wait on another, and Postgres had no way to tell."
pubDate: 2026-11-11
tags: ['Go', 'PostgreSQL', 'Reliability']
draft: true
---

I was writing the Postgres store for a small CI service in Go. Creating a run
means inserting one row into `runs` and a few rows into `checks`, and both have
to land together, so they go in one transaction. Once the tests passed, I
broke the code on purpose to make sure they would notice.

The change was one word: I replaced `tx.Exec` with `s.pool.Exec` for the
`checks` insert. I expected a red test. What I got was a test that **hung**.

## The code, and the one-word bug

This is the shape of `Create`, using `pgx.BeginFunc`. It commits if the
function returns `nil` and rolls back on an error or panic:

```go
err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
	err := tx.QueryRow(ctx, qRun, id, r.Repo, r.Commit, r.Status, r.CreatedAt).
		Scan(&r.ID, &r.CreatedAt)
	if err != nil {
		return err
	}
	for _, c := range r.Checks {
		// The bug: s.pool instead of tx.
		if _, err := s.pool.Exec(ctx, qCheck, id, c.Name, c.Status); err != nil {
			return err
		}
	}
	return nil
})
```

It compiles and reads fine. `s.pool.Exec` and `tx.Exec` have the same
signature. The only difference is which connection the query goes to.

## What Postgres saw

While the test was stuck, I queried `pg_stat_activity`:

```sql
SELECT pid, state, wait_event, pg_blocking_pids(pid) AS blocked_by, query
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid();
```

```
 pid  |        state        | wait_event | blocked_by | query
------+---------------------+------------+------------+-------------------------
 5578 | idle in transaction | ClientRead | {}         | INSERT INTO runs (...)
 ...                                                    (11 rows)
```

Eleven sessions, all `idle in transaction`, all waiting on `ClientRead`, and
`blocked_by` empty for every one. None of them was waiting on a lock. **Each
one was waiting for the client to send its next query.** From Postgres's
point of view nothing was wrong. It had eleven open transactions and was
waiting for the application to continue them.

## A deadlock inside the connection pool

The cause was the pool size. By default, `pgxpool` allows
`max(4, runtime.NumCPU())` connections. My laptop has 11 cores, so the pool
had 11 connections.

The contract tests run `Create` from many goroutines at once. Each call went
through these steps:

1. `BeginFunc` takes a connection from the pool and opens a transaction.
2. The `runs` insert runs on that connection.
3. The `checks` insert asks the **pool** for a second connection.

With 11 or more concurrent calls, step 1 uses up all 11 connections. Every
goroutine then blocks in step 3, waiting for a connection that only another
goroutine can release. None of them will, because each is waiting for its own
second connection.

This is a classic deadlock, but it happens **in Go, not in the database**.
Postgres has a deadlock detector, and it would break a cycle of transactions
waiting on each other's row locks. Here no transaction waits on a lock, so
the detector has nothing to find. The pool doesn't detect it either: it just
sees callers waiting for a free connection. The only thing that ends the wait
is a deadline on `ctx`, and the test didn't set one.

## Without load, the same bug looks completely different

When I ran a single `Create` with no concurrency, it didn't hang. It failed:

```
ERROR: insert or update on table "checks" violates foreign key constraint
"checks_run_id_fkey" (SQLSTATE 23503)
```

With a free connection available, the `checks` insert ran on a different
connection, outside the transaction. That connection can't see the `runs` row,
because the row isn't committed yet. So the foreign key check fails.

That's what makes this bug unpleasant. It's one mistake with two symptoms:

- **Low traffic:** an occasional FK violation that looks like a data problem.
  The run clearly exists by the time you look, so it's hard to explain.
- **High traffic:** the service stops responding. Every connection is stuck,
  so even requests that have nothing to do with creating runs can't get one.

In production you'd most likely see the first symptom in development and the
second during your first traffic spike.

## How I guard against it now

**Inside a transaction, every query goes through `tx`.** That's the whole rule,
but a rule that lives only in my head won't survive a refactor, so I back it
up in a few places:

- **Give helpers a `pgx.Tx`, not the store.** The insert logic now lives in a
  function that receives only the transaction:

  ```go
  func insertRun(ctx context.Context, tx pgx.Tx, id uuid.UUID, r *Run) error
  ```

  Inside `insertRun`, `s.pool` isn't in scope, so the mistake can't be typed.
- **Leave a comment where the mistake would happen.** Above every
  `BeginFunc` there's a note: *"Every query inside must go through tx: s.pool
  would take another connection, outside the transaction."* It's cheap, and
  it's aimed at the next person who adds a query there, which could be me.
- **Put deadlines on contexts.** A request context with a timeout turns
  "hangs forever" into an error you can see. It doesn't fix the bug, but it
  limits the damage to a few slow requests instead of a stuck process.
- **Don't count on `idle_in_transaction_session_timeout`.** I expected it to
  break the cycle from the database side, so I tried it. Postgres did
  terminate the idle sessions after two seconds, but the process stayed stuck.
  The pool still counted all 11 connections as checked out, because the
  goroutines holding them were themselves waiting for the pool. Killing the
  sessions on the server doesn't return the connections to the pool.
- **Test concurrently.** Here the concurrent contract test helped me. Without
  it I'd only have seen the FK error, and probably blamed the test data.

## The takeaway

The test I expected to fail didn't fail. It hung. That was the better outcome,
because a hang made it obvious that something was fundamentally wrong, while an
occasional FK error would have been easy to dismiss.

If you take one thing from this: **a query that skips the transaction isn't a
small mistake.** Under load it can stall the whole service, and Postgres won't
tell you.
