import { getCollection, type CollectionEntry } from 'astro:content';

export type Post = CollectionEntry<'blog'>;

/**
 * Every post that should be public, newest first.
 * Drafts and future-dated posts are visible in `astro dev` so they can be
 * previewed, and dropped from production builds so they never reach S3.
 * A finished post can be committed with its real pubDate and will go live on
 * the first production build on or after that date (pubDate is midnight UTC).
 */
export async function getPublishedPosts(): Promise<Post[]> {
  const now = Date.now();
  const posts = await getCollection(
    'blog',
    ({ data }) => import.meta.env.PROD !== true || (!data.draft && data.pubDate.valueOf() <= now),
  );

  return posts.sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());
}

/** All tags in use, with post counts, alphabetical. */
export async function getAllTags(): Promise<{ tag: string; count: number }[]> {
  const posts = await getPublishedPosts();
  const counts = new Map<string, number>();

  for (const post of posts) {
    for (const tag of post.data.tags) {
      counts.set(tag, (counts.get(tag) ?? 0) + 1);
    }
  }

  return [...counts.entries()]
    .map(([tag, count]) => ({ tag, count }))
    .sort((a, b) => a.tag.localeCompare(b.tag));
}

export function postUrl(post: Post): string {
  return `/blog/${post.id}/`;
}

/** Tags become URL segments, so keep them to a predictable lowercase form. */
export function tagSlug(tag: string): string {
  return tag.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

export function tagUrl(tag: string): string {
  return `/blog/tags/${tagSlug(tag)}/`;
}

/**
 * Stable issue number for a post ("N° 007"): its position in publication
 * order, oldest first, so new posts never renumber the old ones.
 */
export function postNumber(post: Post, all: Post[]): string {
  const oldestFirst = all.length - all.findIndex((p) => p.id === post.id);
  return String(oldestFirst).padStart(3, '0');
}
