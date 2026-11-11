---
title: "We stored a parsed tree of LLM output, and the UI stopped fixing broken Markdown"
description: "Our frontend had 1,500 lines of code that repaired broken Markdown from the LLM. Then the backend started storing a parsed tree, the UI rendered it directly, and new content skipped every repair. Here's why the repairs belong on the server."
pubDate: 2026-11-12
tags: ['AI', 'Architecture', 'TypeScript']
---

LLMs write Markdown that is *almost* right. The table is fine except the header
row is missing. The heading starts in the middle of a paragraph. The whole
answer is wrapped in a ```` ```markdown ```` fence. Sometimes you get a literal
`\n` instead of a newline. Any product that renders generated text ends up with
code that repairs these mistakes.

Ours lived on the frontend: about 1,500 lines of repair functions in a single
utility file, backed by roughly 180 test cases. It worked. Then we made a
reasonable change somewhere else, and every newly generated report section
quietly stopped getting repaired.

This post is about how that happened, and the RFC I wrote to fix it: move
normalization to the server and store a **normalized, versioned syntax tree**
as the canonical format for generated content.

## How the repairs got skipped

The original pipeline was simple. The backend stored the LLM's Markdown
string. The browser repaired it, parsed it, and rendered it:

```
LLM → string (stored) → [browser: repair → parse → render]
```

Later the backend started building an MDAST tree (the
[mdast](https://github.com/syntax-tree/mdast) format that remark uses) from
the same string, so it could attach citation data to links and serve a
structured representation. The UI was updated to prefer that tree whenever it
was present, which is a sensible thing to do: why parse in the browser if the
server already did it?

```
LLM → string → [server: parse] → tree (stored) → [browser: render]
```

Look at what's missing. The server parsed the **raw** LLM output, because
the repairs only existed in the browser. The browser no longer parsed
anything, so it never ran them. Legacy sections without a tree still went
through the old string path and looked fine. New sections rendered glued
tables and stray fences.

Nobody broke the repair code. It just stopped being on the path. An older
design doc even had this as an open question: *"Does the backend build the
tree from normalized Markdown?"* When I traced it, the answer was no.

## Once I looked, the copies were everywhere

The parity bug was the visible symptom. Looking for every place that touched
generated Markdown turned up more:

| Concern | Where it lived |
| --- | --- |
| Markdown repairs | the main frontend utility, a separate modal for OCR text, and two export Lambdas (PDF and DOCX), each with its own partial copy |
| Citation marker cleanup | three implementations across two backends and the frontend |
| Markdown → tree with citations | a background worker, an API service, and the browser |
| Tree → DOCX/PDF | about 2,200 lines of client-side converters, plus the export Lambdas |

Each copy had drifted a little. A report could look right on screen and wrong
in the PDF, because the PDF Lambda's repair function had never learned about
the missing-header case.

Two other problems came from the same habit of fixing content wherever it
happens to be rendered.

**The browser was producing canonical data.** In a couple of flows, like
accepting an AI-drafted edit, the browser built the tree itself and PATCHed
it to the server. So whatever repair code that particular browser tab had
loaded became part of the stored record. Two users on different deploys
could save structurally different trees from the same text.

**Chat rendered differently while streaming and after reload.** Streamed
deltas went through one regex helper; stored messages went through another.
The same answer could change shape when you refreshed the page.

## The proposal: one library, one canonical format

The RFC has three parts.

### 1. A single server-side package

One package owns everything that turns LLM text into structure:

```ts
normalize(md: string): string          // the ported repair chain
parse(md: string, refs): Root          // Markdown → MDAST, citations resolved
serialize(tree: Root): string          // MDAST → Markdown for prompts and legacy readers
normalizeCitationMarkers(md: string)   // the one chat implementation
ReportMdastRootSchema                  // Zod schema for stored trees
MDAST_VERSION                          // bumped when normalize/parse output changes
```

Every code path that builds a tree calls `normalize` first: generation
workers, content-only PATCHes, regenerate, previews.

### 2. The tree is canonical, and it has a version

Generated content is stored as `contentMdast` plus an integer `mdastVersion`.
The Markdown string becomes **derived**: it's serialized from the tree and
kept because LLM prompts and older consumers need it.

The version number does most of the work. Repairs will keep changing, because
models keep finding new ways to break Markdown. With a version on every
record, "I improved the table repair" becomes a backfill query:

```sql
-- rebuild everything older than the current normalizer
WHERE content_mdast IS NULL OR mdast_version < :current
```

It also gives you a rollback path. Without it, you can't tell which stored
trees came from which version of the repair code.

### 3. The UI renders and nothing else

The browser keeps the work that really belongs to the UI: rendering, term and
text-to-speech highlighting, citation labels, sanitization, and editing. It
stops repairing content and stops sending trees it built itself. Edits still
go `editor → tree → PATCH`, but the server validates the tree against the
schema and derives the string. The client no longer sends `content` at all.

For chat, the server normalizes and parses the final answer and sends the
tree in the `message_end` event. While tokens are streaming, the client
renders them with a plain parse and no repairs. At `message_end` it swaps in
the server's tree in one re-render that keeps the scroll position. After
that, a reloaded message renders from exactly the same tree.

## Porting 1,500 lines without changing a single render

The riskiest part is the port itself. Repair code like this is full of
ordering dependencies and edge cases that someone fixed at 11pm and never
wrote down.

So the first phase, before any backend code, is a **parity corpus**:

- Extract the existing inline test cases (about 200 of them) into JSON
  fixtures shaped like `input → normalized → mdast`.
- Add about 50 anonymized production sections that depend on the repairs.
- Run the same fixtures against the frontend implementation and the new
  package.

The port is done when both implementations pass the same corpus. Before
writing the backfill, I also dry-run it on a production sample and review
the structural diffs, because normalizing old content *will* change how some
of it looks, and someone should decide that on purpose.

The rest of the rollout follows from that:

1. Shared corpus (1–2 days)
2. Package, normalize-before-parse everywhere, version column, backfill
   (about a week)
3. Report UI drops the string fallback and stops building trees, but only
   after the backfill is verified
4. Chat: server-side parse, tree in `message_end`, delete the regex helpers
5. Summaries and OCR text
6. Exports read trees, and the client-side repair code is deleted

Removing the UI fallback for sections without a tree is its own PR, after the
backfill is verified. While some records have trees and some don't, the
fallback is what keeps the old ones rendering.

## The takeaway

If your product renders LLM output, you're going to write repair code. The
mistake isn't writing it. The mistake is letting it live wherever the content
happens to be displayed, because the day someone adds a smarter path that
skips that place, the repairs silently stop running.

Pick one place where raw model output becomes structured data, put every
repair there, version what it produces, and treat everything downstream as a
renderer. And before you port the repairs, write down what "same output"
means as a shared test corpus. That corpus is the only way to know the port
didn't change anything.
