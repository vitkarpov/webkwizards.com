// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://webkwizards.com',

  // S3 website hosting resolves `/blog/post/` to `/blog/post/index.html`, so
  // directory-style output with trailing slashes avoids an origin 302 hop.
  trailingSlash: 'always',
  build: { format: 'directory' },

  integrations: [sitemap()],

  markdown: {
    shikiConfig: {
      theme: 'github-light',
      wrap: true,
    },
  },
});
