#!/usr/bin/env bash
# deploy.sh — repeatable upload: push index.html to S3 and invalidate the
# CloudFront edge cache. Safe to run any time after provisioning.
#
# Takes no arguments. Reads BUCKET, DISTRIBUTION_ID, DISTRIBUTION_DOMAIN
# from deploy.env (written by provision.sh) — no duplicated literals here.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f deploy.env ]; then
  echo "ERROR: deploy.env not found — run ./provision.sh first" >&2
  exit 1
fi

# shellcheck source=deploy.env disable=SC1091
source ./deploy.env

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS session is expired or unauthenticated. Run: aws login" >&2
  exit 1
fi

aws s3 cp index.html "s3://${BUCKET}/index.html" \
  --cache-control "public, max-age=300" \
  --content-type "text/html; charset=utf-8"

aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*"

echo "Deployed. Site: https://${DISTRIBUTION_DOMAIN}/"
