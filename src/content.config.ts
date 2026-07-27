import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

/**
 * Blog posts are Markdown files in src/content/blog/.
 * The filename (minus extension) becomes the URL slug: `my-post.md` -> /blog/my-post/
 * Frontmatter is validated at build time — a typo fails the build instead of shipping.
 */
const blog = defineCollection({
  loader: glob({ base: './src/content/blog', pattern: '**/*.md' }),
  schema: z.object({
    title: z.string().max(120),
    /** Used for the list excerpt, meta description, and RSS summary. */
    description: z.string().max(300),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    tags: z.array(z.string()).default([]),
    /** Drafts render in `astro dev` but are excluded from production builds. */
    draft: z.boolean().default(false),
    /** Social preview image, e.g. "/images/my-post.png" from public/. */
    image: z.string().optional(),
  }),
});

export const collections = { blog };
