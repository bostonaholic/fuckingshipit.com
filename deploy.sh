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

# `source` executes deploy.env as shell, so refuse anything but plain
# KEY=value constants — a tampered file must not be able to run commands.
while IFS= read -r line; do
  if ! [[ "$line" =~ ^[A-Z_]+=[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: deploy.env has a line that is not a plain KEY=value constant: ${line}" >&2
    exit 1
  fi
done < deploy.env

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
