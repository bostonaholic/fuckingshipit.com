#!/usr/bin/env bash
# provision.sh — one-time AWS setup for the static site: S3 bucket, ACM
# certificate, CloudFront distribution with Origin Access Control.
#
# Rerunnable by design: it pauses on human DNS work at Namecheap, so the
# expected path is two runs (request cert + print validation records, then
# wait ISSUED + create the distribution). Every resource has a stable
# lookup key, so re-runs reuse instead of duplicating.
#
# Takes no arguments. Fails fast on an expired AWS session.
set -euo pipefail

DOMAIN=fuckingshipit.com
WWW=www.fuckingshipit.com
BUCKET=fuckingshipit-com
REGION=us-east-1
OAC_NAME=fuckingshipit-com-oac
CALLER_REFERENCE=fuckingshipit-com-static-site
ORIGIN_ID=s3-fuckingshipit-com

# Turn an ACM validation record name into a Namecheap-ready Host.
# ACM returns ResourceRecord.Name fully qualified WITH a trailing dot
# ("_abc123.fuckingshipit.com."), so the trailing dot must be stripped
# FIRST — until it is gone, the ".fuckingshipit.com" suffix is not at the
# end of the string and never matches. Getting the order wrong rebuilds
# "_abc123.fuckingshipit.com.fuckingshipit.com" at Namecheap and hangs
# ACM validation for 72 hours with no useful error.
# Applies ONLY to ACM-derived names; the final "@" and "www" Hosts are
# literals and never pass through here.
strip_acm_name() {
  local name=$1
  name=${name%.}
  name=${name%".${DOMAIN}"}
  printf '%s\n' "$name"
}

require_auth() {
  if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo "ERROR: AWS session is expired or unauthenticated. Run: aws login" >&2
    exit 1
  fi
}

ensure_bucket() {
  local err
  if err=$(aws s3api head-bucket --bucket "$BUCKET" 2>&1); then
    echo "Bucket ${BUCKET} already exists — reusing."
  elif [[ "$err" == *"403"* ]]; then
    echo "ERROR: head-bucket returned 403 for ${BUCKET}." >&2
    echo "A 403 means the bucket name exists in ANOTHER AWS account (bucket names are global), not that it is absent." >&2
    echo "Pick a different BUCKET constant; this script does not auto-rename." >&2
    exit 1
  else
    echo "Creating bucket ${BUCKET} in ${REGION}..."
    # us-east-1 takes no LocationConstraint.
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  fi
  # Enforce Block Public Access on the reuse path too: an adopted bucket
  # created before April 2023 can have BPA off. Full BPA does not block
  # the OAC bucket policy — a service principal scoped by AWS:SourceArn
  # is not "public" to S3.
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}

# Reuse a certificate only when it covers BOTH names: matching DomainName
# alone could reuse a pre-existing apex-only cert and then fail at
# create-distribution on the second alias. Never request a second cert
# when one is pending — new CNAMEs would orphan records already pasted.
ensure_certificate() {
  CERT_ARN=$(aws acm list-certificates --region "$REGION" \
    --certificate-statuses ISSUED PENDING_VALIDATION \
    --query "CertificateSummaryList[?contains(not_null(SubjectAlternativeNameSummaries, \`[]\`), '${DOMAIN}') && contains(not_null(SubjectAlternativeNameSummaries, \`[]\`), '${WWW}')] | [0].CertificateArn" \
    --output text)
  if [ -n "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    echo "Reusing certificate ${CERT_ARN} (covers ${DOMAIN} and ${WWW})."
    return
  fi
  echo "Requesting certificate for ${DOMAIN} + ${WWW} (DNS validation, ${REGION})..."
  # The cert MUST live in us-east-1 — CloudFront reads certs only there.
  CERT_ARN=$(aws acm request-certificate --region "$REGION" \
    --domain-name "$DOMAIN" \
    --subject-alternative-names "$WWW" \
    --validation-method DNS \
    --query CertificateArn --output text)
}

# ResourceRecord is briefly absent right after request-certificate;
# printing then would emit an empty Host/Value table. Poll until every
# DomainValidationOptions entry has one. One describe-certificate call
# per attempt: both counts must come from the same snapshot, or a record
# publish landing between two calls would compare mismatched states.
wait_for_validation_records() {
  local attempt counts total missing
  for attempt in $(seq 1 12); do
    # SC2016 is a false positive on this query: the backticks are
    # JMESPath raw-literal syntax (`[]`, `null`), not shell command
    # substitution — single quotes keep the shell away from them
    # (unescaped inside double quotes they WOULD run as command
    # substitution). not_null guards BOTH counts because
    # DomainValidationOptions can be absent right after
    # request-certificate, and length(null) is a query error that would
    # kill the script mid-poll under set -e.
    # shellcheck disable=SC2016
    counts=$(aws acm describe-certificate --region "$REGION" \
      --certificate-arn "$CERT_ARN" \
      --query '[length(not_null(Certificate.DomainValidationOptions, `[]`)), length(not_null(Certificate.DomainValidationOptions, `[]`)[?ResourceRecord == `null`])]' \
      --output text)
    read -r total missing <<<"$counts"
    if [ "$total" -ge 1 ] && [ "$missing" -eq 0 ]; then
      return 0
    fi
    echo "Validation records not published yet (attempt ${attempt}/12); retrying in 5s..."
    sleep 5
  done
  echo "ERROR: ACM did not publish validation ResourceRecords within ~60s." >&2
  echo "Re-run this script once ACM catches up: aws acm describe-certificate --region ${REGION} --certificate-arn ${CERT_ARN}" >&2
  exit 1
}

# Host is already Namecheap-ready: paste Host and Value verbatim, no rule
# to apply.
print_validation_records() {
  local name value host
  echo ""
  echo "Add these validation records at Namecheap (paste Host and Value verbatim):"
  echo "Type  | Host | Value"
  while read -r name value; do
    host=$(strip_acm_name "$name")
    echo "CNAME | ${host} | ${value}"
  done < <(aws acm describe-certificate --region "$REGION" \
    --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord.[Name,Value]' \
    --output text)
  echo ""
}

# Nothing below this gate is reachable without ISSUED: creating a
# distribution against a non-ISSUED cert is a mess to unwind.
ensure_issued() {
  local status
  status=$(aws acm describe-certificate --region "$REGION" \
    --certificate-arn "$CERT_ARN" \
    --query Certificate.Status --output text)
  if [ "$status" = "ISSUED" ]; then
    echo "Certificate is ISSUED."
    return
  fi
  echo "Certificate status is ${status}; waiting for ISSUED (up to ~40 min)..."
  echo "If the records are not at Namecheap yet, paste them now — the table above has them."
  if ! aws acm wait certificate-validated --region "$REGION" --certificate-arn "$CERT_ARN"; then
    echo "ERROR: certificate never reached ISSUED." >&2
    echo "Diff the expected records below against what is actually at Namecheap, fix, and re-run." >&2
    print_validation_records >&2
    exit 1
  fi
  echo "Certificate is ISSUED."
}

ensure_oac() {
  OAC_ID=$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'] | [0].Id" \
    --output text)
  if [ -n "$OAC_ID" ] && [ "$OAC_ID" != "None" ]; then
    echo "Reusing origin access control ${OAC_NAME} (${OAC_ID})."
    return
  fi
  echo "Creating origin access control ${OAC_NAME}..."
  OAC_ID=$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "Name=${OAC_NAME},OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4" \
    --query OriginAccessControl.Id --output text)
}

managed_response_headers_policy_id() {
  local id
  id=$(aws cloudfront list-response-headers-policies --type managed \
    --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='Managed-SecurityHeadersPolicy'] | [0].ResponseHeadersPolicy.Id" \
    --output text)
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "ERROR: managed response headers policy Managed-SecurityHeadersPolicy not found." >&2
    exit 1
  fi
  printf '%s\n' "$id"
}

require_setting() { # <setting-name> <live-value> <expected-value>
  if [ "$2" != "$3" ]; then
    echo "ERROR: distribution ${DISTRIBUTION_ID} has drifted: ${1} is '${2}', expected '${3}'." >&2
    echo "Fix it in the CloudFront console (or delete the distribution) and re-run — this script does not auto-repair live config." >&2
    exit 1
  fi
}

# Drift check for the reuse path. The TLS and security-header settings
# are only ever WRITTEN by the create branch, so a distribution edited in
# the console — back to TLSv1, or with the headers policy detached —
# would otherwise survive every re-run silently. Fail loud, naming the
# drifted setting; an unexpected live config deserves a human decision,
# not a blind overwrite.
verify_distribution_settings() {
  local expected_headers_id live viewer_policy min_protocol ssl_method headers_id
  expected_headers_id=$(managed_response_headers_policy_id)
  live=$(aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" \
    --query "DistributionConfig.[DefaultCacheBehavior.ViewerProtocolPolicy, ViewerCertificate.MinimumProtocolVersion, ViewerCertificate.SSLSupportMethod, not_null(DefaultCacheBehavior.ResponseHeadersPolicyId, 'DETACHED')]" \
    --output text)
  read -r viewer_policy min_protocol ssl_method headers_id <<<"$live"
  require_setting ViewerProtocolPolicy "$viewer_policy" redirect-to-https
  require_setting MinimumProtocolVersion "$min_protocol" TLSv1.2_2021
  require_setting SSLSupportMethod "$ssl_method" sni-only
  require_setting ResponseHeadersPolicyId "$headers_id" "$expected_headers_id"
}

# Lookup by alias BEFORE any create — aliases are globally unique. The
# stable CallerReference is the fail-loud backstop: if the lookup ever
# misses an existing distribution, create-distribution errors instead of
# minting a duplicate.
ensure_distribution() {
  DISTRIBUTION_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(not_null(Aliases.Items, \`[]\`), '${DOMAIN}')] | [0].Id" \
    --output text)
  if [ -n "$DISTRIBUTION_ID" ] && [ "$DISTRIBUTION_ID" != "None" ]; then
    DISTRIBUTION_DOMAIN=$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" \
      --query Distribution.DomainName --output text)
    verify_distribution_settings
    echo "Reusing distribution ${DISTRIBUTION_ID} (${DISTRIBUTION_DOMAIN})."
    return
  fi

  local cache_policy_id response_headers_policy_id config created
  cache_policy_id=$(aws cloudfront list-cache-policies --type managed \
    --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingOptimized'] | [0].CachePolicy.Id" \
    --output text)
  if [ -z "$cache_policy_id" ] || [ "$cache_policy_id" = "None" ]; then
    echo "ERROR: managed cache policy Managed-CachingOptimized not found." >&2
    exit 1
  fi
  response_headers_policy_id=$(managed_response_headers_policy_id)

  config=$(cat <<EOF
{
  "CallerReference": "${CALLER_REFERENCE}",
  "Comment": "${DOMAIN} static site",
  "Enabled": true,
  "Aliases": { "Quantity": 2, "Items": ["${DOMAIN}", "${WWW}"] },
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "${ORIGIN_ID}",
        "DomainName": "${BUCKET}.s3.${REGION}.amazonaws.com",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "${ORIGIN_ID}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "${cache_policy_id}",
    "ResponseHeadersPolicyId": "${response_headers_policy_id}",
    "Compress": true
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      { "ErrorCode": 403, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 300 },
      { "ErrorCode": 404, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 300 }
    ]
  },
  "PriceClass": "PriceClass_100",
  "ViewerCertificate": {
    "ACMCertificateArn": "${CERT_ARN}",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  }
}
EOF
)
  echo "Creating CloudFront distribution for ${DOMAIN} + ${WWW}..."
  created=$(aws cloudfront create-distribution --distribution-config "$config" \
    --query 'Distribution.[Id,DomainName]' --output text)
  DISTRIBUTION_ID=$(cut -f1 <<<"$created")
  DISTRIBUTION_DOMAIN=$(cut -f2 <<<"$created")
}

# Overwrite-safe on re-run. Grants only s3:GetObject, and only to this
# distribution (the SourceArn condition), so direct S3 URLs stay denied.
attach_bucket_policy() {
  local dist_arn policy
  dist_arn="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DISTRIBUTION_ID}"
  policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipal",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": { "StringEquals": { "AWS:SourceArn": "${dist_arn}" } }
    }
  ]
}
EOF
)
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$policy"
}

write_outputs() {
  cat > deploy.env <<EOF
BUCKET=${BUCKET}
DISTRIBUTION_ID=${DISTRIBUTION_ID}
DISTRIBUTION_DOMAIN=${DISTRIBUTION_DOMAIN}
EOF
  echo "Wrote deploy.env (BUCKET, DISTRIBUTION_ID, DISTRIBUTION_DOMAIN)."
  echo ""
  echo "Final DNS records for Namecheap (after the distribution deploys):"
  echo "Type  | Host | Value"
  echo "ALIAS | @    | ${DISTRIBUTION_DOMAIN}"
  echo "CNAME | www  | ${DISTRIBUTION_DOMAIN}"
  echo ""
  echo "Next step — wait for the distribution to finish deploying:"
  echo "  aws cloudfront wait distribution-deployed --id \"${DISTRIBUTION_ID}\""
}

main() {
  # deploy.env must land next to this script — its consumers (deploy.sh,
  # check.sh) cd to their own directory before reading it. Inside main,
  # not at file scope, so sourcing stays side-effect-free.
  cd "$(dirname "$0")" || exit 1
  require_auth
  ensure_bucket
  ensure_certificate
  wait_for_validation_records
  print_validation_records
  ensure_issued
  ensure_oac
  ensure_distribution
  attach_bucket_policy
  write_outputs
}

# Source guard: `source ./provision.sh` defines functions and executes
# nothing, which is what makes strip_acm_name unit-testable with no AWS.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
