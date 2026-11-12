# webkwizards.com

Landing page and blog for Viktor Karpov — Fractional CTO. A statically generated
[Astro](https://astro.build) site served from S3 behind CloudFront, with
infrastructure managed by Terraform.

No JavaScript ships to the browser: every page is HTML and CSS generated at build
time, including syntax highlighting.

## Requirements

| Tool | Version | Notes |
| --- | --- | --- |
| Node | 22.12+ | `nvm use` picks it up from `.nvmrc`. Astro 7 requires it. |
| AWS CLI | v2 | Authenticated against the `webkwizards` profile. |
| Terraform | 1.0+ | Only needed for infrastructure changes. |

## Local development

```bash
nvm use
npm install
npm run dev      # http://localhost:4321
```

Astro 7 runs the dev server as a background daemon:

```bash
npx astro dev status
npx astro dev logs
npx astro dev stop
```

Other scripts:

```bash
npm run build     # generate dist/
npm run preview   # serve dist/ locally
npm run check     # typecheck .astro and .ts files
```

## Writing a post

Posts are Markdown files in `src/content/blog/`. The filename becomes the URL:
`my-post.md` publishes to `/blog/my-post/`.

```bash
cp docs/post-template.md src/content/blog/my-post.md
```

`docs/post-template.md` documents every frontmatter field and exercises each
element the stylesheet supports (headings, lists, quotes, code, tables, images).
It lives outside `src/content/blog/`, so it is never published.

Minimum frontmatter:

```yaml
---
title: The post title
description: One or two sentences, used as the list excerpt, meta description, and RSS summary.
pubDate: 2026-07-27
tags: ['Architecture', 'AI']
draft: true
---
```

Frontmatter is validated against the schema in `src/content.config.ts` at build
time — a missing or misspelled field fails `npm run build` rather than shipping
broken metadata.

Set `draft: true` while writing. Drafts render at `npm run dev` but are excluded
from production builds, so they cannot reach S3. Delete the line to publish.

Each tag automatically gets an archive page at `/blog/tags/<slug>/`, and posts
are added to `/rss.xml` and the sitemap.

> Until the first post exists, `npm run build` prints
> `The collection "blog" does not exist or is empty`. That is expected and goes
> away as soon as `src/content/blog/` contains a Markdown file.

## Project layout

```
astro.config.mjs           site URL, trailing slashes, sitemap, Shiki theme
src/
  consts.ts                site-wide strings (titles, email, links)
  content.config.ts        blog collection + frontmatter schema
  content/blog/            posts (Markdown) — the only place content lives
  layouts/BaseLayout.astro <head>, metadata, page shell
  components/              Header, Footer, PostList
  pages/
    index.astro            landing page
    404.astro
    rss.xml.ts             RSS feed
    blog/index.astro       post list
    blog/[...slug].astro   individual post
    blog/tags/[tag].astro  tag archive
  lib/                     post queries, date and reading-time helpers
  styles/
    global.css             design tokens + shell (header, footer, buttons)
    home.css               landing page sections
    blog.css               post list + article typography
public/                    served verbatim (robots.txt, images)
docs/post-template.md      copy this to start a post
deploy.sh                  build + publish
main.tf, variables.tf, outputs.tf
```

The design system lives in `src/styles/global.css` as CSS custom properties
(`--paper`, `--ink`, `--accent`, `--mono`, `--sans`). Change a token there and it
applies to the landing page, the blog, and the 404 page together.

## Deploying

Deploys normally happen in GitHub Actions (`.github/workflows/deploy.yml`):
on every push to `main`, every day at 07:00 UTC, and on demand from the Actions
tab. Production builds exclude posts whose `pubDate` is in the future, so the
daily run publishes scheduled posts on their date with no manual step.
Commit a finished post with its real `pubDate`; use `draft: true` only for
posts that aren't ready.

The workflow authenticates to AWS through the OIDC role in `github-actions.tf`,
so the repository holds no AWS keys. Creating that role needs IAM permissions
beyond PowerUserAccess, so apply it once with an admin login.

GitHub pauses scheduled workflows in repositories with no activity for 60
days. Pushing a commit, or re-enabling the workflow in the Actions tab,
resumes it.

To deploy from your machine instead:

```bash
aws sso login --profile webkwizards   # once per session
./deploy.sh
```

`deploy.sh` builds the site and syncs `dist/` to S3, then invalidates CloudFront.
It refuses to run if credentials are invalid or the build produced no
`dist/index.html`.

Cache headers are set per file type, which is why content is no longer uploaded
by Terraform:

| Files | `Cache-Control` | Why |
| --- | --- | --- |
| `_astro/*` | `max-age=31536000, immutable` | Filenames contain a content hash. |
| HTML, `rss.xml`, sitemaps | `max-age=0, must-revalidate` | A new post must never sit invisible in a cache. |

Assets are uploaded before pages and are **not** deleted, so a visitor still on
the previous HTML keeps resolving the files it references. Pages are synced with
`--delete` so removed posts stop returning 200.

To prune orphaned assets from earlier builds:

```bash
aws s3 sync dist/ "s3://webkwizards.com/" --delete --exclude "*" --include "_astro/*" --profile webkwizards
```

Overrides: `SKIP_BUILD=1` publishes the existing `dist/`, and `BUCKET` /
`DISTRIBUTION_ID` / `AWS_PROFILE` bypass the Terraform lookups.

### One-time migration step

Terraform used to upload the old single-file `index.html` as
`aws_s3_object.index`. That resource has been removed from `main.tf`, so the
**next `terraform apply` would delete `index.html` from the bucket** and take the
site down until the following deploy.

Run this once, before the next apply, to make Terraform forget the object without
touching the file in S3:

```bash
terraform state rm aws_s3_object.index
```

Then confirm the plan is clean apart from the `error_document` change:

```bash
terraform plan
```

## Infrastructure

- **S3** — static website hosting. The website endpoint (not the REST endpoint)
  is the CloudFront origin, so it resolves `/blog/post/` to
  `/blog/post/index.html` on its own. That is why clean URLs work without a
  CloudFront Function, and why `astro.config.mjs` sets
  `trailingSlash: 'always'`.
- **CloudFront** — HTTPS, compression, global distribution. `error_document` is
  `404.html`, so unknown paths render the styled 404 page.
- **ACM** — TLS certificate for `webkwizards.com` and `www`, in `us-east-1`.
- **Route 53** — DNS, with A-record aliases for the apex and `www`.

Applying infrastructure changes:

```bash
terraform init
terraform plan
terraform apply
```

Useful outputs: `terraform output` exposes `website_url`, `s3_bucket_name`,
`cloudfront_distribution_id`, and `route53_zone_id`.

## Troubleshooting

**A deleted or renamed post still appears in the build.** The content layer
caches parsed entries. Clear it and rebuild:

```bash
npx astro dev stop
rm -rf node_modules/.astro dist
npm run build
```

**Changes are not visible on the live site.** Check the invalidation finished:

```bash
aws cloudfront get-invalidation --distribution-id "$(terraform output -raw cloudfront_distribution_id)" --id <invalidation-id> --profile webkwizards
```

**Certificate validation is stuck.** Verify the validation records exist and have
propagated:

```bash
aws route53 list-resource-record-sets --hosted-zone-id "$(terraform output -raw route53_zone_id)"
dig _acme-challenge.webkwizards.com
```

**Domain not resolving.** Confirm the registrar's nameservers match Route 53:

```bash
aws route53 get-hosted-zone --id "$(terraform output -raw route53_zone_id)" --query 'DelegationSet.NameServers'
```

## Cost

Roughly **$1–2/month**, almost entirely Route 53 ($0.50 per hosted zone plus
query charges). S3 storage for a text site is negligible, CloudFront stays inside
the free tier at this traffic level, and the ACM certificate is free.

## Cleanup

```bash
terraform destroy
```

Removes the CloudFront distribution, S3 bucket and contents, ACM certificate, and
the Route 53 records. The hosted zone survives, since it is read via a data
source rather than managed here.
