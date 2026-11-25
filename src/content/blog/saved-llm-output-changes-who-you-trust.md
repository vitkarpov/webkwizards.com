---
title: "We started saving the LLM's answer, so the client couldn't send the question anymore"
description: "Sky's Format endpoint took the text to format from the browser. That was harmless while the result stayed in one browser tab. Once the result was saved and shown to everyone on the case, the input had to come from the server, and guests had to lose a permission they never knew they had."
pubDate: 2027-01-27
tags: ['Security', 'AI', 'Architecture']
---

Sky's Summary tab has a Format button: type an instruction, a model rewrites
the summary, and the new version appears in place. The endpoint behind it was
small. The browser sent the summary it was showing plus the instruction, the
server checked that the page or section belonged to the case, called the
model, and returned the text.

Nothing was saved. The result lived in the browser's cache until the next
reload.

Then we decided to save it, so a formatted summary would survive a reload and
everyone on the case would see the same one. The model call and the prompt
didn't change. The endpoint's security did, completely, and it took two
separate changes to catch up.

## A harmless endpoint

Here's the old request:

```ts
// POST /organizations/:org/projects/:project/summary/format
{
  entityType: "page" | "section",
  entityId: string,
  content: string,       // the summary text, as the browser had it
  instructions?: string,
}
```

The server never looked at where `content` came from. It verified the entity
belonged to the case, and that was it:

```ts
const page = await req.prisma.page.findFirst({
  where: { id: entityId, document: { folderInstances: { some: {
    folderId: projectId, folder: { organizationId },
  } } } },
});
if (!page) return res.status(404).json({ error: "Page not found" });

const formattedContent = await formatContent(content, instructions);
return res.status(200).json({ formattedContent });
```

That was fine. If you sent text that wasn't the real summary, you got back a
formatted version of your own text, in your own tab. The worst case was using
the endpoint as a general text formatter, and the endpoint already tracked
usage and checked billing for that.

## Saving the result changes the threat model

Once the result is stored and served instead of the generated summary, the
same request means something else. Anyone who can call the endpoint can make
any text the summary that everyone on the case sees:

```ts
{ entityType: "section", entityId: "…", content: "Whatever I want it to say" }
```

No prompt injection needed. A formatting model reflows whatever it's given, so
the saved summary says what the request said. For a product that summarizes
legal case files, a summary that doesn't match the documents is about the worst
thing it can show.

It also breaks the bookkeeping. Each saved row records which generated summary
it was made from, so it stops being served when that summary changes. With
client-supplied content, that record is a claim the server never checked.

### The server formats its own summary

So the request stopped carrying the text. Format loads the summary the same way
the Summary tab does, through the same function, and formats that:

```ts
const current = await getEntitySummary(req, entityType, entityId);
if (current.sourceKey === null) {
  throw new ApiError("A blank summary cannot be formatted", 400);
}
const formatted = await withCurrentTree({
  content: await formatContent(current.content, instructions),
});
```

Getting the summary from the server also makes "the current summary" mean the
same thing everywhere. Two cases needed handling once the server was the
source.

**Blank pages.** A blank page doesn't get a model summary. It gets a fixed
"This is a blank page" message with no cache key. A formatted version of that
message could never be matched to a summary, so it would be saved and never
shown. Format now rejects blank entities with a 400.

**Stale sections.** A section whose pages changed is marked stale until the
processing pipeline reruns. The summary code used to keep reading the
pipeline's old output for those sections. It now builds them from the current
pages, so Format and the Summary tab both work from what the section contains
today.

### Old clients during the rollout

The app and the API deploy separately, so for a while old app versions keep
sending `content`. Rejecting it would break Format for them.

The spec marks the field deprecated, with "Ignored; the server formats the
summary it has." On the server, the DTO no longer declares it, and the
request validator runs with `whitelist: true`, which strips any property the
DTO doesn't declare. An old client's `content` is dropped before the handler
sees it.

The response went the other way. Format now returns the same shape as the
summary endpoint, so the app can put the result straight into its summary
cache. It also keeps the old `formattedContent` field, marked deprecated,
until old clients are gone.

## Who is allowed to write

The second half came from review. Two automated reviewers flagged it
independently on the pull request: guests could overwrite the shared summary.

Sky lets you share a case with a guest through a link. Guests can read the
case, including summaries, and the Format route allowed them because its
access check was the guest check: does this caller have access to this case?
That was the right check when Format was a read. Saving made it a write, and
the route didn't notice.

Regenerate had the same problem from the other direction. With the formatted
summary saved, Regenerate clears it, so a guest pressing Regenerate could
erase the formatting everyone else saw.

The fixes are small:

```ts
app.post(
  "/api/organizations/:organizationId/projects/:projectId/summary/format",
  // … auth, validation, billing …
  checkOrgRole(FULL_ACCESS_ROLES),
  validateProjectOwnership(),
  ensureGuestCaseAccess(),
  formatSummary
);
```

`FULL_ACCESS_ROLES` is the existing list of every role except guest. For
Regenerate, guests still get a freshly generated summary, but only full-access
members clear the saved formatting:

```ts
// Guests get a fresh summary but leave the shared formatted one in place.
if (force && canEditSummaries(req)) {
  await clearFormattedSummary(req.prisma, projectId, entityType, entityId);
}
```

The app hides the Format button for guests, but that's a convenience. The
route is what enforces it.

## What didn't change

The prompt, the model and the instruction limit are the same. The log line
still records the entity and the lengths of the content and the instructions,
not the text: summaries of legal files don't belong in logs, saved or not.

## The takeaway

Persisting a result changes an endpoint's threat model even when its code
barely changes. Before you start saving something you used to just return, go
through four questions:

1. **Where does the input come from?** If the client supplies it, the client
   now decides what gets saved. Read it on the server instead.
2. **Who can call this?** Read permission was enough for a computation. A
   write that others will see needs write permission, and every other path
   that touches the saved data needs the same check.
3. **Who reads the result?** One user's tab and the whole case are different
   audiences, with different ideas of a "harmless" bad result.
4. **What do old clients send?** Deprecate fields in the spec and ignore them
   on the server, rather than rejecting them mid-rollout.
