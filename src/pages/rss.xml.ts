import rss from '@astrojs/rss';
import type { APIContext } from 'astro';
import { BLOG_DESCRIPTION, BLOG_TITLE } from '../consts';
import { getPublishedPosts, postUrl } from '../lib/posts';

export async function GET(context: APIContext) {
  const posts = await getPublishedPosts();

  return rss({
    title: BLOG_TITLE,
    description: BLOG_DESCRIPTION,
    site: context.site!,
    items: posts.map((post) => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.pubDate,
      link: postUrl(post),
      categories: post.data.tags,
    })),
    customData: '<language>en-gb</language>',
  });
}
