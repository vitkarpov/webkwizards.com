---
title: "Saving LLM output turned a slow request into a race"
description: "Sky started saving formatted summaries. A format takes seconds of model time, and a Regenerate that finishes during those seconds was being overwritten by the older result. The cache key couldn't see it. A revision counter could."
pubDate: 2027-01-20
tags: ['PostgreSQL', 'AI', 'Architecture']
---

Sky's Summary tab has a Format button. You type an instruction like "Tidy up"
or "Bullet the key dates", a model rewrites the summary, and the result shows
up in place. Until recently that result lived only in the browser's cache.
Reload the page and it was gone.

So we started saving it: a new Postgres table, one row per formatted summary,
served to everyone on the case. The first version passed its tests. Two
automated reviewers then found the same bug in it: a formatted summary could
silently undo a Regenerate that finished after it started.

This post is about why that happens, why the obvious invalidation key couldn't
catch it, and the small revision counter that does.

## Where summaries live

Generated summaries aren't in the database. They're in Redis, under a key built
from everything that went into the prompt:

```ts
const cacheKey =
  `summary_v3:${org}:${project}:${entityType}:${entityId}` +
  `:${industry}:${lang}:${source}:${contentHash}:${summaryLength}`;
```

`contentHash` is a hash of the page or section text. If someone edits a page,
the hash changes, the key changes, and the next read is a cache miss that
generates a new summary. Nothing has to delete the old one.

The formatted summary piggybacks on this. Its row stores the cache key of the
summary it was made from, in a `sourceKey` column, and it's served only while
that key still matches:

```ts
const formatted = await findFormattedSummary(prisma, projectId, type, id);
if (formatted?.content != null && formatted.sourceKey === cacheKey) {
  return { content: formatted.content, /* … */ };
}
const cachedSummary = await redis.get(cacheKey);
```

Edit a page and the formatted version stops being served, for the same reason
the old summary does. That part worked.

## The race

Regenerate is a different kind of change. It doesn't touch the source text. It
skips the cache, asks the model again, and writes the new summary to **the same
key**, because the inputs are the same. The first version also deleted the
formatted row, so the fresh summary would show.

Now put a Format in front of it. Formatting is an LLM call too, so it takes a
few seconds:

```
t0  Format      reads summary A, sends it to the model
t1  Regenerate  writes summary B to the cache key, deletes the formatted row
t2  Format      model returns; saves formatted(A) with sourceKey = cache key
t3  any read    sourceKey matches, serves formatted(A) instead of B
```

The user pressed Regenerate, saw summary B, and on the next load got a
formatted version of the summary they had just thrown away.

The `sourceKey` check can't catch this, and that's the interesting part. The
key describes the summary's **inputs**. Regenerate changes the **output** and
keeps every input the same. As far as the key can tell, formatted(A) is still a
perfectly good derivative of the current summary.

## Why not a lock

The textbook answer is to serialize the two operations. Take a row lock, or
open a transaction, read the summary, call the model, save.

That means holding a database connection and a lock across an LLM call that
takes seconds and sometimes much longer. A Regenerate on the same summary would
queue behind it. Worse, a slow or hung model call would pin a pool connection
for its whole duration. Conflicts here are rare: two people acting on the same
summary within the same few seconds. That's the case for optimistic
concurrency. Let both run, and make the loser notice at write time.

## A revision counter

The row gets an integer `revision`. Every write that changes what the row means
bumps it, and Format saves only if the revision is still the one it saw at the
start:

```ts
const { count } = await prisma.formattedSummary.updateMany({
  where: { folderId, sectionId, revision },
  data: { ...formatted, revision: revision + 1 },
});
return count > 0;
```

If Regenerate ran in between, the `WHERE` matches nothing, `count` is 0, and
Format answers 409: "The summary changed while it was being formatted. Try
again." This is the same compare-and-swap idea I used for
[CI run states](/blog/compare-and-swap-state-machine-in-sql/), with a counter
instead of a status.

Regenerate's side bumps the revision and clears the saved text in one
statement:

```ts
await prisma.formattedSummary.updateMany({
  where: { folderId, sectionId },
  data: {
    revision: { increment: 1 },
    sourceKey: null,
    content: null,
    contentMdast: Prisma.DbNull,
    mdastVersion: null,
  },
});
```

Two details took more thought than the counter itself.

### Regenerate can't delete the row

Deleting the row looks like the natural way to clear it. It would break the
case where no one has formatted the summary yet:

```
t0  Format      no row exists, remembers "no row"
t1  Regenerate  nothing to delete
t2  Format      inserts formatted(A); nothing says it's stale
```

"No row" can't carry a revision, so Regenerate has to leave something behind.
It creates a row with empty content and `revision: 1` if none exists, and bumps
the existing one otherwise:

```ts
const { count } = await prisma.formattedSummary.createMany({
  data: [{ folderId, sectionId, revision: 1 }],
  skipDuplicates: true,
});
if (count > 0) return;
// a row already exists: bump it and clear the content (the update above)
```

Format's insert for the no-row case uses the same shape. Prisma's `create`
throws on a unique violation. `createMany` with `skipDuplicates` becomes
`INSERT … ON CONFLICT DO NOTHING` and returns a count, so losing the race is a
normal return value instead of an exception. If Regenerate's empty row got
there first, Format's insert does nothing, and it answers 409 like any other
lost race.

### Read the revision before the summary

The order of the two reads at the start of Format matters:

```ts
const previous = await findFormattedSummary(prisma, projectId, type, id);
const current = await getEntitySummary(req, type, id);
// … call the model on current.content …
await saveFormattedSummary(/* … */, previous?.revision ?? null, /* … */);
```

Read them the other way round and the race comes back. Format reads summary A,
Regenerate finishes and bumps the revision to 2, Format reads revision 2, and
its save matches. Reading the revision first means any Regenerate that could
have changed the summary Format is working from also changed the revision it
will compare against.

## Two more ways a saved copy goes stale

The same reviews found two smaller problems, both from the same root: a saved
derivative only stays correct if everything that changes its source also
reaches it.

**Removed pages didn't change the key.** Sections are summarized from a YAML
file the processing pipeline writes. Removing a page from a section marks it
`summaryStale`, but the summary code still read the old YAML, so the content
hash, the cache key and the formatted summary all stayed put. Stale sections
now skip the YAML and are summarized from their current pages, which changes
the hash.

**Deleted sections left their formatted text behind.** The table only had a
foreign key to the case, so deleting a section or a page kept its row until
the whole case was deleted. The section and page columns are now cascading
foreign keys too. One schema detail makes this layout work: each row has
either a `sectionId` or a `pageId`, and the unique constraints are
`(folderId, sectionId)` and `(folderId, pageId)`. Postgres treats NULLs as
distinct in unique indexes, so all the page rows, whose `sectionId` is NULL,
don't collide with each other.

## Did it need a backfill?

After the merge, the first question was whether existing formatted summaries
had to be migrated into the new table. They didn't. The old endpoint returned
the formatted text and saved nothing, so there was nothing on the server to
move. The table ships empty, every read falls back to the generated summary,
and rows appear the first time someone presses Format or Regenerate.

## The takeaway

Saving the result of a slow call turns it into a write that lands long after
its inputs were read. Anything that changes those inputs in the meantime has
to be detectable at write time.

A content-based key is great for invalidation, but it only sees changes to the
inputs it hashes. If an operation can change the output while keeping the
inputs, like a regenerate, a retry or a model change, you need something that
moves when the output moves. Here that was an integer, a conditional
`UPDATE`, and a placeholder row so that "nothing saved yet" also has a revision.
