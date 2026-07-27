# Post template and formatting reference

This file lives outside `src/content/blog/`, so it is never published. Copy it to
start a new post:

```bash
cp docs/post-template.md src/content/blog/my-new-post.md
```

The filename becomes the URL — `my-new-post.md` publishes to `/blog/my-new-post/`.

Start the file with frontmatter:

```yaml
---
title: Post template and formatting reference
description: One or two sentences used as the list excerpt, meta description, and RSS summary.
pubDate: 2026-07-27
tags: ['Architecture', 'AI']
draft: true
---
```

Keep `draft: true` while writing — the post is then visible at `npm run dev`
but excluded from production builds. Remove it (or set `false`) to publish.

## Frontmatter

| Field | Required | Notes |
| --- | --- | --- |
| `title` | yes | Max 120 chars. Shown in `<title>`, OG tags, and the post list. |
| `description` | yes | Max 300 chars. Doubles as the list excerpt, meta description, and RSS summary. |
| `pubDate` | yes | `YYYY-MM-DD`. Controls sort order and the RSS feed. |
| `updatedDate` | no | Renders an "Updated" line in the post header. |
| `tags` | no | Array of labels. Each one gets an archive page at `/blog/tags/<slug>/`. |
| `draft` | no | Defaults to `false`. `true` keeps it out of production builds. |
| `image` | no | Path in `public/`, e.g. `/images/my-post.png`, used for social previews. |

The schema in `src/content.config.ts` validates all of this at build time — a typo
fails `npm run build` rather than shipping broken metadata.

## Headings

Use `##` for top-level sections; the page `<h1>` comes from `title`, so never
write one in the body.

### Third-level heading

#### Fourth-level heading

## Text elements

Regular paragraph text with **bold**, *italic*, `inline code`, and a
[link to the homepage](/).

- Unordered list item
- Another item, with a nested list:
  - Nested item
- Third item

1. Ordered list item
2. Second item
3. Third item

> Blockquotes get an accent bar on the left. Good for pulling out the one
> sentence you want someone to remember.

---

## Code blocks

Fenced blocks are highlighted at build time by Shiki — no client-side JS:

```ts
interface Post {
  title: string;
  pubDate: Date;
  tags: string[];
}

export function isRecent(post: Post): boolean {
  const thirtyDays = 30 * 24 * 60 * 60 * 1000;
  return Date.now() - post.pubDate.valueOf() < thirtyDays;
}
```

## Images

Put files in `public/images/` and reference them with an absolute path:

```md
![Alt text that describes the image](/images/example.png)
```

Always write real alt text — it's the only description a screen reader gets.
