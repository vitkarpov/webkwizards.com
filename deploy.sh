#!/usr/bin/env bash
#
# Build the site and publish it to S3 + CloudFront.
#
#   ./deploy.sh
#
# Overrides via environment:
#   AWS_PROFILE       AWS profile to use            (default: webkwizards)
#   BUCKET            target S3 bucket              (default: from terraform output)
#   DISTRIBUTION_ID   CloudFront distribution       (default: from terraform output)
#   SKIP_BUILD=1      publish the existing dist/ without rebuilding
#
set -euo pipefail

cd "$(dirname "$0")"

export AWS_PROFILE="${AWS_PROFILE:-webkwizards}"

for cmd in aws npm; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' is not installed" >&2; exit 1; }
done

# Resolve targets from Terraform state unless supplied explicitly.
BUCKET="${BUCKET:-$(terraform output -raw s3_bucket_name)}"
DISTRIBUTION_ID="${DISTRIBUTION_ID:-$(terraform output -raw cloudfront_distribution_id)}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "error: AWS credentials for profile '$AWS_PROFILE' are not valid." >&2
  echo "       Run: aws sso login --profile $AWS_PROFILE" >&2
  exit 1
fi

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "==> Building"
  npm run build
fi

# Guard against publishing a broken or empty build.
[[ -s dist/index.html ]] || { echo "error: dist/index.html is missing or empty — refusing to deploy" >&2; exit 1; }

echo "==> Uploading hashed assets to s3://${BUCKET}"
# Filenames in _astro/ contain a content hash, so they can be cached forever.
# No --delete here: a visitor still on the previous HTML must keep resolving the
# assets it references. Prune old ones deliberately (see README).
aws s3 sync dist/ "s3://${BUCKET}/" \
  --exclude "*" \
  --include "_astro/*" \
  --cache-control "public, max-age=31536000, immutable" \
  --no-progress

echo "==> Uploading pages and feeds"
# HTML and feeds must always be revalidated, otherwise a published post can sit
# invisible in a CDN or browser cache. --delete removes pages taken down since
# the last deploy.
aws s3 sync dist/ "s3://${BUCKET}/" \
  --delete \
  --exclude "_astro/*" \
  --cache-control "public, max-age=0, must-revalidate" \
  --no-progress

# rss.xml defaults to application/xml; the feed-specific type is more correct.
aws s3 cp "s3://${BUCKET}/rss.xml" "s3://${BUCKET}/rss.xml" \
  --metadata-directive REPLACE \
  --content-type "application/rss+xml; charset=utf-8" \
  --cache-control "public, max-age=0, must-revalidate" \
  --no-progress

echo "==> Invalidating CloudFront ${DISTRIBUTION_ID}"
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' --output text)

echo "==> Done. Invalidation ${INVALIDATION_ID} in progress."
echo "    https://webkwizards.com"
