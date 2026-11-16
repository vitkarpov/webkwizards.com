---
title: "The model didn't ignore the instruction. It ran out of tokens."
description: "A Format button that did nothing looked like an LLM ignoring a prompt, and I almost shipped a prompt fix. Reproducing the exact call showed the model was fine: its JSON reply was cut off at the default output token limit, and nothing checked why it stopped."
pubDate: 2026-12-30
tags: ['AI', 'TypeScript', 'Reliability']
---

Sky's report editor has a **Format** button on every section. You type an
instruction like "Use a numbered list", click Apply, and an LLM rewrites the
section's Markdown. A browser test did exactly that on a generated report
section, twice. Both times Format finished without any visible error, and the
section stayed a bullet list, even after a page refresh.

That looks like the model ignoring an instruction. That's what I thought, and I
had a fix half written before I found out I was wrong.

## The obvious theory

The prompt opened like this:

> You are a professional text editor. Tidy up the markdown formatting of the
> provided text. Preserve all original content, meaning, and structure. Only
> improve formatting, readability, and markdown syntax.

The user's request came after that, as "Additional instructions". The model
was a small, fast one with reasoning turned down to a minimum. A bullet list
*is* structure. "Preserve structure" in the system text against "use a
numbered list" tacked on at the end: it's easy to believe the first one wins.

I traced the rest of the path to rule it out:

- the request sends the section's current Markdown;
- the backend returns whatever the model returned;
- the client parses `1. …` into an ordered list node (I checked with a test);
- the save stores what it's sent, and the renderer shows ordered lists with
  numbers.

Every step checked out, which left the model. I wrote a new prompt that put the
user's instructions first and said they override the defaults, including
changes to structure. It read well, and it was wrong.

## Reproduce before you fix

Before shipping a prompt change, I wanted to see the model actually ignore the
instruction. So I made the same call the backend makes: same model, same
temperature, same JSON response schema, same rendered prompt, through the same
gateway client code, with the dev API key. The input was a short bullet list
with citation links.

| Prompt | "Use a numbered list" |
| --- | --- |
| current | numbered, 3 runs out of 3 |
| rewritten | numbered, 3 runs out of 3 |

The current prompt worked every time. The model did what it was asked. Whatever
broke the button, it wasn't the instruction.

## The logs had the answer

I should have started here. The backend logs for the test run had two lines,
one per attempt:

```
Error formatting report section …: Unterminated string in JSON at position 17363
```

The model hadn't ignored anything. Its reply was **cut off**. The endpoint
returned a 500, and the UI showed a short "Failed to format section" toast that
the test (and probably a real user) never noticed. The section stayed as it
was because nothing was saved.

The format call asks for structured output: a JSON object with one string
field, `formattedText`. The prompt config set no `max_tokens`, so the gateway
used its default of 8,192 output tokens. My test section was a few hundred
characters. A real report section is not.

Generated report sections carry citations as HTML anchors:

```html
<a class="source-map-link" href="#ref-12" data-section-id="…" data-page-id="…" data-first-page-id="…" data-ref-number="12">12</a>
```

Three UUIDs per citation, often two citations per bullet. The visible text is
a modest list. The Markdown behind it is long, and a rewrite has to reproduce
all of it, escaped inside a JSON string.

## My first reproduction hid the bug

To confirm, I built a big section: 32 bullets, two citations each, about 18 KB.
The default limit handled it fine. The output was only 2,400 characters.

The model had returned **4** items. I'd built the section by repeating the
same four bullets, and the model merged the duplicates, even though the prompt
told it to preserve all content. That's worth knowing by itself. But it also
meant my test didn't measure what I wanted, because the output came out much
smaller than the input.

With distinct items (different dates, providers and findings: 28 bullets, 56
citations, 18.5 KB) it reproduced on the first try:

| Output limit | Result (2 runs each) |
| --- | --- |
| default, 8,192 tokens | `Unterminated string in JSON at position 15313`, both runs |
| 32,768 tokens | valid JSON, 28 of 28 items numbered, both runs |

Test data for an LLM bug has to be realistic in ways that never matter for
ordinary code. A repetitive fixture would be fine for testing a parser. Here it
changed the size of the output, which was the one thing the bug depended on.

## The fixes

**Size the output budget for the output.** For a rewrite, the output is about
as long as the input, and longer once it's escaped inside JSON. The format
config now sets `max_tokens: 32768`. Nothing ever compared the token limit
with the size of the input. Presumably most sections were short enough that
nobody hit it.

**Check why the model stopped.** The gateway took Gemini's response and passed
the text along whatever the `finishReason` was. A reply cut off at
`MAX_TOKENS` looked exactly like a complete one until someone ran
`JSON.parse` on it. Now, for structured requests, the gateway fails loudly:

```ts
if (response.candidates?.[0]?.finishReason === "MAX_TOKENS") {
  if (responseMimeType === "application/json") {
    throw new StatusError(
      `Gemini response was truncated at the output token limit (maxOutputTokens: ${maxTokens}), so the JSON is incomplete. Raise max_tokens for this prompt.`,
      502
    );
  }
  logger.warn("Gemini response was truncated at the output token limit", {
    model: modelName,
    maxOutputTokens: maxTokens,
  });
}
```

A cut-off JSON reply is never usable, so it's an error, and it now names the
cause instead of a character position. A cut-off plain-text reply can still be
useful, so it's returned as before, with a warning in the logs. Because the
check throws before the cache is written, truncated replies are no longer
cached.

## One more thing on the same route

While I was in the gateway, I noticed the structured-output route never read
the `thinking_level` parameter. The backend sent it on every call, and the
format config asked for minimal reasoning. The route dropped it, and Gemini
used its own default.

Fixing that is the right call, but it's also a behaviour change. Six features
use that route, and each one now runs at the reasoning level its config asks
for instead of whatever the model defaults to. A parameter that's ignored
doesn't break anything until you stop ignoring it.

## The takeaway

When an LLM feature "does nothing", the model ignoring the prompt is the most
satisfying explanation and the easiest one to act on. It's also cheap to test:
make the exact production call and look at what comes back. Here it saved me
from shipping a prompt change that would have passed on short sections and
failed again on the next long report.

Then check how the response ended, not only what it says. Every major LLM API
tells you why generation stopped. For structured output, anything other than a
normal stop means the JSON is broken before you parse it. Check that once, in
the layer every call goes through, and set the token limit for the size of the
output you expect, not the size of the prompt.
