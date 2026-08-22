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

# deploy.env is parsed as data, never executed, so a tampered file
# cannot run commands or shadow variables this script depends on (PATH,
# IFS, ...). Only the three expected keys are accepted, each exactly
# once, with values limited to the characters AWS identifiers use — and
# never starting with a hyphen, so no value can take the shape of a CLI
# option. The
# `|| [ -n "$line" ]` keeps a final line with no trailing newline from
# skipping validation: `read` returns non-zero on it but still fills
# $line.
BUCKET='' DISTRIBUTION_ID='' DISTRIBUTION_DOMAIN=''
while IFS= read -r line || [ -n "$line" ]; do
  if ! [[ "$line" =~ ^(BUCKET|DISTRIBUTION_ID|DISTRIBUTION_DOMAIN)=([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    echo "ERROR: deploy.env has a line that is not one of the three expected KEY=value constants: ${line}" >&2
    exit 1
  fi
  key=${BASH_REMATCH[1]}
  if [ -n "${!key}" ]; then
    echo "ERROR: deploy.env sets ${key} more than once" >&2
    exit 1
  fi
  printf -v "$key" '%s' "${BASH_REMATCH[2]}"
done < deploy.env

for key in BUCKET DISTRIBUTION_ID DISTRIBUTION_DOMAIN; do
  if [ -z "${!key}" ]; then
    echo "ERROR: deploy.env is missing ${key}" >&2
    exit 1
  fi
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS session is expired or unauthenticated. Run: aws login" >&2
  exit 1
fi

# Assets upload before the page, so index.html never references a key
# that is not in the bucket yet.
aws s3 cp og-image.png "s3://${BUCKET}/og-image.png" \
  --cache-control "public, max-age=300" \
  --content-type "image/png"

aws s3 cp favicon.ico "s3://${BUCKET}/favicon.ico" \
  --cache-control "public, max-age=300" \
  --content-type "image/x-icon"

aws s3 cp index.html "s3://${BUCKET}/index.html" \
  --cache-control "public, max-age=300" \
  --content-type "text/html; charset=utf-8"

aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*"

echo "Deployed. Site: https://${DISTRIBUTION_DOMAIN}/"
