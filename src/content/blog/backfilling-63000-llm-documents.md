---
title: "Backfilling 63,000 LLM-written documents without overwriting a single edit"
description: "Sky now stores a normalized, versioned syntax tree for every generated report section. Existing sections needed one too. Here's how the backfill avoided users' edits, why its dry run logged structure instead of text, and the two bugs it caught first."
pubDate: 2027-01-13
tags: ['AI', 'PostgreSQL', 'Architecture']
---

In November I wrote about
[moving LLM Markdown repairs to the server](/blog/llm-markdown-repairs-belong-on-the-server/).
At Sky, every generated report section is now normalized once, parsed into an
MDAST tree, and stored with an integer `mdastVersion`. The browser renders the
tree and stops repairing anything.

That covers new content. Existing sections still needed the same treatment:
some had a tree built from raw, unrepaired Markdown, and most had no tree at
all. This post is about the backfill that fixed them: 16,347 sections on dev,
63,238 in production, with zero overwritten edits.

## Pick rows by what's out of date

The backfill doesn't track progress anywhere. Each batch is selected by what
still needs work:

```sql
SELECT id FROM "ReportSection"
WHERE status = 'completed' AND archived = false AND content IS NOT NULL
  AND (
    "contentMdast" IS NULL
    OR "mdastVersion" IS NULL
    OR "mdastVersion" < :current
    OR "sourceContent" IS NULL
    OR content IS DISTINCT FROM "sourceContent"
  )
  AND id > :cursor
ORDER BY id
LIMIT :batch
```

Two properties follow from that. The backfill is **idempotent**: once a row is
current it no longer matches, so a second run finds nothing. It's also
**resumable**: if a run is killed halfway, the next one picks up whatever is
left, with nothing to clean up. The `id > :cursor` keyset keeps a single run
moving forward even when rows are skipped.

The last condition covers a writer that predates the new columns. If something
changed `content` without maintaining `sourceContent`, the stored tree may no
longer match the text, so the row gets rebuilt.

## Three outcomes per row

For each row, the backfill builds the new tree from the section's content and
decides what to write:

- **stamp**: the stored tree renders exactly like the new one, so only the
  version (and the preserved source) is written. The existing tree stays
  untouched, along with its citation metadata.
- **rebuild**: the stored tree differs, so it's replaced. Citation metadata
  is carried over from the old tree.
- **build**: there was no tree.

"Renders exactly like" needs a definition that ignores irrelevant differences.
Two trees from the same text can split inline text into nodes differently, or
carry different link metadata, and still look identical. So the comparison
uses a signature of what a reader sees: each top-level block's shape plus its
text with whitespace collapsed. The backfill never assumes the stored tree is
right just because normalization leaves the text unchanged. It always builds
the new tree and compares.

## Don't overwrite an edit made mid-run

Users edit sections while the backfill runs. Every write is conditional on
the row being unchanged since it was read:

```ts
const { count } = await prisma.reportSection.updateMany({
  where: { id: row.id, updatedAt: row.updatedAt },
  data: {
    sourceContent: plan.sourceContent,
    mdastVersion: MDAST_VERSION,
    contentMdast: plan.tree,
    // Not a user edit: keep the timestamp other writers compare with.
    updatedAt: row.updatedAt,
  },
});
if (count === 0) summary.conflicts += 1;
```

If someone saved the section in between, `updatedAt` no longer matches and
the update touches zero rows. The backfill counts a conflict and moves on, and
the next run picks that row up, since it still matches the selection query.

Notice that the write sets `updatedAt` to its **old** value. The backfill
isn't an edit. If it bumped the timestamp, every editor that also uses
`updatedAt` as its compare-and-swap token would see a conflict it didn't
cause, and the section would look recently edited to anyone sorting by it.

## A dry run that logs structure, not text

Normalizing old content changes how some of it looks. That's the point. But
someone should look at what changes before it happens. So the backfill has a
dry-run mode that writes nothing and logs every row whose block structure
would change.

These are medical and legal reports, so the log can't contain any text. It
logs the **shape** of the document instead, meaning node types nested without
content:

```json
{
  "message": "mdast-backfill.diff",
  "action": "rebuild",
  "sectionId": "…",
  "before": "paragraph|paragraph|paragraph",
  "after": "paragraph|list(listItem(paragraph))|paragraph|list(listItem(paragraph))|paragraph|list(listItem(paragraph))"
}
```

That's enough to review. The example above is three paragraphs that are
really three short introductions, each followed by a bullet list that had
been flattened into its paragraph. After normalization they render as lists.
You can read the diff without seeing a word of anyone's report, and
aggregating it is a CloudWatch Logs Insights query:

```
fields before, after
| filter message = 'mdast-backfill.diff' and action = 'rebuild'
| stats count(*) as n by before, after
| sort n desc
```

## The dry run caught two bugs first

The first dev dry run, before any write, turned up two problems in the
normalizer itself.

**Four sections took 20 to 267 seconds to parse.** Each had a table delimiter
row of hundreds of thousands of dashes. The record was a run of 745,000. The
cause is remark-gfm's email autolink transform. It matches
`[-.\w+]+@`, and starts over after every punctuation character, so a long run
of `-`, `.`, `_` or `+` takes time proportional to the square of its length.
Run inside a worker or the API, a section like that blocks it for minutes.

A delimiter cell or a horizontal rule renders the same at any length, so the
fix is to shorten such runs before parsing: punctuation runs to 256
characters, and mixed word-and-punctuation runs to 4,096, far longer than any
real slug, hash or token. The four sections now take 252 to 270 ms.

**A repair could make text disappear.** One repair splits a line where a
block (a list item, a heading) has been glued onto the end of a sentence. If
the piece left over happened to read as a complete Markdown link reference
definition, `[label]: https://…`, the parser treated it as a definition, and
definitions don't render. The text silently vanished. Now, when a split leaves
something that looks like a definition, its opening bracket is escaped, so it
stays visible text. Real definitions in the input are left alone.

Both fixes change the normalizer's output for some inputs, so they bumped
`MDAST_VERSION` to 2. The version did exactly what the earlier post promised:
every tree built by version 1 matched the selection query again. On dev, all
16,347 sections were re-checked. The new normalizer changed the text of 11 of
them, and 6 of those rendered differently enough to get a new tree. The rest
were stamped.

## The numbers

The backfill runs as a one-off ECS task, started from a GitHub Actions
workflow, with a dry run and a review before each real run. (Getting that
task to stop when it was done was its own story; see
[ECS restarted my one-off task, twice](/blog/ecs-restart-policy-reran-my-backfill/).)

| | Dev | Production |
| --- | ---: | ---: |
| Sections scanned | 16,347 | 63,238 |
| Tree built for the first time | 0 | 55,564 |
| Tree rebuilt | 6 | 410 |
| Already current, stamped | 16,341 | 7,264 |
| Conflicts | 0 | 0 |
| Errors | 0 | 0 |
| Duration | 8 min | 38 min |

Dev had been backfilled once before, with version 1, so this run only had the
two fixes left to apply. Production was a different picture: almost nine in
ten sections had never had a stored tree at all. Until now, they'd been
repaired in the browser every time someone opened them.

The production dry run's diff log covers 397 of the rebuilt sections. Most of
them change the same few ways:

| Change | Sections |
| --- | ---: |
| Paragraphs become proper bullet lists | 132 |
| Missing paragraph breaks restored | 102 |
| A heading split off the sentence it was glued to | 57 |
| Merged list items split apart | 46 |
| A broken table becomes a table | 2 |

About one in ten rebuilt sections kept exactly the same shape and just got a
better tree.

## What made it boring

A backfill over production content should be uneventful, and this one was. I
think three choices made that possible:

1. **Select by state, not by progress.** With no progress table or checkpoint
   file, a killed run isn't a problem, and a second run is a no-op.
2. **Make every write conditional, and don't pretend to be an edit.** Zero
   conflicts happened, but the run didn't depend on that.
3. **Review a dry run you're allowed to read.** Logging the shape of each
   document instead of its text made the diff reviewable without touching
   anyone's data. It also caught two normalizer bugs before they reached a
   single stored row.

The version number is what turns all of this into routine maintenance. The
next time a model finds a new way to break Markdown, the fix bumps the
version, and the same backfill, with the same dry run, brings every stored
section up to date.
