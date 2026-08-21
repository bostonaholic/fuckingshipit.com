#!/usr/bin/env bash
# check.sh — acceptance tests for the static-site-s3-cloudfront change.
#
# Usage:
#   ./check.sh        run every slice's assertions (the full acceptance gate)
#   ./check.sh 1      run one slice's assertions in isolation (1 through 5)
#
# Each assertion prints exactly one PASS/FAIL line. Failures carry the
# reason in parentheses. Exit 0 only when every assertion passes.
# To add an assertion, add one helper call inside the relevant slice_N
# function — no framework, no registration.
#
# Deliberately NOT `set -e`: failing assertions are expected output here,
# not reasons to abort. `-u` and `pipefail` still catch script bugs.
set -u -o pipefail

cd "$(dirname "$0")" || exit 1

PASS=0
FAIL=0
HTML=index.html

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s (%s)\n' "$1" "$2"; }

# Assert a fixed string is present in a file.
assert_present() { # <file> <fixed-string> <description>
  local file=$1 needle=$2 desc=$3
  if [ ! -f "$file" ]; then fail "$desc" "$file does not exist"; return; fi
  if grep -qF -- "$needle" "$file"; then
    pass "$desc"
  else
    fail "$desc" "missing: $needle"
  fi
}

# Assert a fixed string is absent from a file (case-insensitive).
# A missing file FAILS: absence in a file that does not exist proves nothing.
assert_absent() { # <file> <fixed-string> <description>
  local file=$1 needle=$2 desc=$3
  if [ ! -f "$file" ]; then fail "$desc" "$file does not exist"; return; fi
  if grep -qiF -- "$needle" "$file"; then
    fail "$desc" "found forbidden: $needle"
  else
    pass "$desc"
  fi
}

# Assert a fixed string occurs exactly N times in a file (case-insensitive).
assert_count() { # <file> <fixed-string> <expected-count> <description>
  local file=$1 needle=$2 want=$3 desc=$4 got
  if [ ! -f "$file" ]; then fail "$desc" "$file does not exist"; return; fi
  got=$(grep -oiF -- "$needle" "$file" | grep -c .)
  if [ "$got" -eq "$want" ]; then
    pass "$desc"
  else
    fail "$desc" "found $got occurrence(s) of '$needle', want $want"
  fi
}

# Assert the first fixed string appears on an earlier line than the second.
assert_order() { # <file> <first> <second> <description>
  local file=$1 first=$2 second=$3 desc=$4 a b
  if [ ! -f "$file" ]; then fail "$desc" "$file does not exist"; return; fi
  a=$(grep -nF -- "$first" "$file" | head -1 | cut -d: -f1)
  b=$(grep -nF -- "$second" "$file" | head -1 | cut -d: -f1)
  if [ -z "$a" ]; then fail "$desc" "missing: $first"; return; fi
  if [ -z "$b" ]; then fail "$desc" "missing: $second"; return; fi
  if [ "$a" -lt "$b" ]; then
    pass "$desc"
  else
    fail "$desc" "'$first' at line $a is not before '$second' at line $b"
  fi
}

# Assert a path does not exist (file or directory).
assert_gone() { # <path> <description>
  if [ -e "$1" ]; then fail "$2" "$1 still exists"; else pass "$2"; fi
}

# Assert strip_acm_name (sourced from provision.sh, no AWS access, no
# execution of main) maps <input> to <expected>.
assert_strip() { # <input> <expected> <description>
  local out
  out=$(bash -c 'source ./provision.sh >/dev/null 2>&1 && strip_acm_name "$1"' _ "$1" 2>/dev/null)
  if [ "$out" = "$2" ]; then
    pass "$3"
  else
    fail "$3" "got '${out:-<no output>}', want '$2'"
  fi
}

# Print every way the deploy.env on stdin violates deploy.sh's contract:
# each line KEY=value with deploy.sh's exact value pattern, each of the
# three keys exactly once. No output means the copy is valid. Reads the
# raw stream (not a $(...) capture) so blank lines — including trailing
# ones, which deploy.sh rejects — are seen, not silently stripped.
deploy_env_violations() {
  awk '
    !/^(BUCKET|DISTRIBUTION_ID|DISTRIBUTION_DOMAIN)=[A-Za-z0-9][A-Za-z0-9._-]*$/ {
      printf "malformed line %d: \"%s\"; ", NR, $0; next
    }
    { split($0, kv, "="); count[kv[1]]++ }
    END {
      n = split("BUCKET DISTRIBUTION_ID DISTRIBUTION_DOMAIN", keys, " ")
      for (i = 1; i <= n; i++)
        if (count[keys[i]] != 1)
          printf "%s appears %d times, expected exactly 1; ", keys[i], count[keys[i]]
    }
  '
}

# AWS stub for the provisioning reuse-path tests below. Each scenario exposes
# only the calls that function is allowed to make; any unexpected call fails
# the test instead of accidentally reaching the real account.
#
# The three calls the drift checks read are stubbed as the JSON the API
# actually returns, not as pre-extracted values, so provision.sh's own jq
# expressions run here. A typo in one of them fails a test instead of
# waiting to fail against live AWS. The list-* lookups still return their
# post-query scalar: reproducing them faithfully would mean reimplementing
# JMESPath filtering in the stub, and no drift check reads them.
# shellcheck disable=SC2329 # Invoked indirectly by the aws() shim below.
provision_aws_stub() {
  local operation="${1:-} ${2:-}"
  case "$operation" in
    's3api head-bucket')
      case "$AWS_STUB_SCENARIO" in
        bucket_*) return 0 ;;
      esac
      ;;
    's3api get-bucket-location')
      # us-east-1 is reported as null, not as its name — the case that
      # makes provision.sh's fallback load-bearing.
      case "$AWS_STUB_SCENARIO" in
        bucket_wrong_region) printf '{"LocationConstraint":"us-west-2"}\n'; return 0 ;;
        bucket_healthy) printf '{"LocationConstraint":null}\n'; return 0 ;;
      esac
      ;;
    's3api put-public-access-block')
      if [ "$AWS_STUB_SCENARIO" = bucket_healthy ]; then return 0; fi
      ;;
    'cloudfront list-origin-access-controls')
      case "$AWS_STUB_SCENARIO" in
        oac_*) printf 'EOAC123\n'; return 0 ;;
      esac
      ;;
    'cloudfront get-origin-access-control')
      case "$AWS_STUB_SCENARIO" in
        oac_*) provision_oac_stub_json; return 0 ;;
      esac
      ;;
    'cloudfront list-response-headers-policies')
      case "$AWS_STUB_SCENARIO" in
        distribution_*) printf 'EHEADERS123\n'; return 0 ;;
      esac
      ;;
    'cloudfront list-cache-policies')
      case "$AWS_STUB_SCENARIO" in
        distribution_*) printf 'ECACHE123\n'; return 0 ;;
      esac
      ;;
    'cloudfront get-distribution-config')
      case "$AWS_STUB_SCENARIO" in
        distribution_*) provision_distribution_stub_json; return 0 ;;
      esac
      ;;
  esac
  printf 'unexpected aws call for %s: %s\n' "$AWS_STUB_SCENARIO" "$*" >&2
  return 99
}

# shellcheck disable=SC2329 # Invoked indirectly by provision_aws_stub.
provision_oac_stub_json() {
  local override='.'
  case "$AWS_STUB_SCENARIO" in
    oac_wrong_type) override='.OriginAccessControl.OriginAccessControlConfig.OriginAccessControlOriginType = "mediastore"' ;;
    oac_wrong_signing) override='.OriginAccessControl.OriginAccessControlConfig.SigningBehavior = "never"' ;;
    oac_wrong_protocol) override='.OriginAccessControl.OriginAccessControlConfig.SigningProtocol = "sigv2"' ;;
  esac
  jq "$override" <<'JSON'
{
  "OriginAccessControl": {
    "Id": "EOAC123",
    "OriginAccessControlConfig": {
      "Name": "fuckingshipit-com-oac",
      "OriginAccessControlOriginType": "s3",
      "SigningBehavior": "always",
      "SigningProtocol": "sigv4"
    }
  }
}
JSON
}

# Every distribution scenario starts from the config the create branch
# writes and mutates exactly ONE field, so a failing test names the check
# that caught it and nothing else. A scenario with no override is the
# healthy baseline.
# shellcheck disable=SC2329 # Invoked indirectly by provision_aws_stub.
provision_distribution_stub_json() {
  local override='.'
  case "$AWS_STUB_SCENARIO" in
    distribution_disabled) override='.DistributionConfig.Enabled = false' ;;
    distribution_wrong_root_object) override='.DistributionConfig.DefaultRootObject = "home.html"' ;;
    distribution_plaintext) override='.DistributionConfig.DefaultCacheBehavior.ViewerProtocolPolicy = "allow-all"' ;;
    distribution_old_tls) override='.DistributionConfig.ViewerCertificate.MinimumProtocolVersion = "TLSv1"' ;;
    distribution_wrong_ssl_method) override='.DistributionConfig.ViewerCertificate.SSLSupportMethod = "vip"' ;;
    distribution_headers_detached) override='del(.DistributionConfig.DefaultCacheBehavior.ResponseHeadersPolicyId)' ;;
    distribution_cache_policy_swapped) override='.DistributionConfig.DefaultCacheBehavior.CachePolicyId = "EOTHERCACHE"' ;;
    distribution_compress_off) override='.DistributionConfig.DefaultCacheBehavior.Compress = false' ;;
    distribution_wrong_cert) override='.DistributionConfig.ViewerCertificate.ACMCertificateArn = "arn:aws:acm:us-east-1:210987654321:certificate/other"' ;;
    distribution_missing_alias) override='.DistributionConfig.Aliases.Items = ["fuckingshipit.com"]' ;;
    distribution_no_custom_errors) override='.DistributionConfig.CustomErrorResponses.Items = []' ;;
    distribution_extra_cache_behavior) override='.DistributionConfig.CacheBehaviors = {"Quantity":1,"Items":[{"PathPattern":"*.html","TargetOriginId":"s3-fuckingshipit-com","ViewerProtocolPolicy":"allow-all"}]}' ;;
    distribution_two_origins) override='.DistributionConfig.Origins.Items += [{"Id":"second","DomainName":"other.example.com"}]' ;;
    distribution_wrong_origin_id) override='.DistributionConfig.Origins.Items[0].Id = "other-origin-id"' ;;
    distribution_wrong_origin) override='.DistributionConfig.Origins.Items[0].DomainName = "other-bucket.s3.us-east-1.amazonaws.com"' ;;
    distribution_origin_path) override='.DistributionConfig.Origins.Items[0].OriginPath = "/staging"' ;;
    distribution_oac_detached) override='del(.DistributionConfig.Origins.Items[0].OriginAccessControlId)' ;;
    distribution_legacy_oai) override='.DistributionConfig.Origins.Items[0].S3OriginConfig.OriginAccessIdentity = "origin-access-identity/cloudfront/E2LEGACY"' ;;
    distribution_custom_origin) override='.DistributionConfig.Origins.Items[0].CustomOriginConfig = {"HTTPPort":80,"OriginProtocolPolicy":"http-only"}' ;;
    distribution_wrong_target) override='.DistributionConfig.DefaultCacheBehavior.TargetOriginId = "other-origin"' ;;
    # The value that used to defeat every check at once. Reading the config
    # as one tab-separated row and splitting it with `read` let a value
    # carrying a newline truncate the row and hand the later fields their
    # expected tokens — so the drifted ViewerProtocolPolicy below was never
    # reached and the whole config passed.
    distribution_newline_in_value)
      override='.DistributionConfig.DefaultRootObject = "index.html\nallow-all\tTLSv1.2_2021\tsni-only"
        | .DistributionConfig.DefaultCacheBehavior.ViewerProtocolPolicy = "allow-all"' ;;
  esac
  jq "$override" <<'JSON'
{
  "DistributionConfig": {
    "CallerReference": "fuckingshipit-com-static-site",
    "Comment": "fuckingshipit.com static site",
    "Enabled": true,
    "DefaultRootObject": "index.html",
    "PriceClass": "PriceClass_100",
    "Aliases": { "Quantity": 2, "Items": ["fuckingshipit.com", "www.fuckingshipit.com"] },
    "Origins": {
      "Quantity": 1,
      "Items": [
        {
          "Id": "s3-fuckingshipit-com",
          "DomainName": "fuckingshipit-com.s3.us-east-1.amazonaws.com",
          "OriginPath": "",
          "OriginAccessControlId": "EOAC123",
          "S3OriginConfig": { "OriginAccessIdentity": "" }
        }
      ]
    },
    "DefaultCacheBehavior": {
      "TargetOriginId": "s3-fuckingshipit-com",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "ECACHE123",
      "ResponseHeadersPolicyId": "EHEADERS123",
      "Compress": true
    },
    "CustomErrorResponses": {
      "Quantity": 2,
      "Items": [
        { "ErrorCode": 403, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 300 },
        { "ErrorCode": 404, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 300 }
      ]
    },
    "ViewerCertificate": {
      "ACMCertificateArn": "arn:aws:acm:us-east-1:123456789012:certificate/test",
      "SSLSupportMethod": "sni-only",
      "MinimumProtocolVersion": "TLSv1.2_2021"
    }
  }
}
JSON
}

# The IDs a reuse path would have already looked up before the drift check
# runs. Set for every scenario: each test gets a fresh subshell that
# re-sources provision.sh, so an unused constant cannot leak into another.
run_provision_test() { # <scenario> <function-name>
  local scenario=$1 function_name=$2
  (
    AWS_STUB_SCENARIO=$scenario
    source ./provision.sh
    # shellcheck disable=SC2329 # Invoked by functions sourced from provision.sh.
    aws() { provision_aws_stub "$@"; }
    DISTRIBUTION_ID=EDIST123
    CERT_ARN=arn:aws:acm:us-east-1:123456789012:certificate/test
    OAC_ID=EOAC123
    "$function_name"
  )
}

assert_provision_rejects() { # <scenario> <function-name> <message-fragment> <description>
  local scenario=$1 function_name=$2 needle=$3 desc=$4 out rc
  out=$(run_provision_test "$scenario" "$function_name" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$needle" &&
    ! printf '%s' "$out" | grep -qF 'unexpected aws call'; then
    pass "$desc"
  else
    fail "$desc" "exit=$rc, output: ${out:-<none>}"
  fi
}

assert_provision_accepts() { # <scenario> <function-name> <message-fragment> <description>
  local scenario=$1 function_name=$2 needle=$3 desc=$4 out rc
  out=$(run_provision_test "$scenario" "$function_name" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qF 'unexpected aws call'; then
    if [ -z "$needle" ] || printf '%s' "$out" | grep -qF -- "$needle"; then
      pass "$desc"
      return
    fi
  fi
  fail "$desc" "exit=$rc, output: ${out:-<none>}"
}

# ---------------------------------------------------------------------------
slice_1() { # index.html — the static page, verifiable locally
  echo "--- Slice 1: the static page (index.html) ---"

  assert_present "$HTML" '<!DOCTYPE html>' 'index.html declares <!DOCTYPE html>'
  assert_present "$HTML" '<meta charset="utf-8">' 'index.html declares utf-8 charset'
  assert_present "$HTML" '<meta name="viewport" content="width=device-width, initial-scale=1">' 'index.html has the viewport meta'

  # The link-preview tags. assert_present is a fixed-string grep over the
  # whole file, so it cannot tell a tag sitting in <head> from one pasted
  # into <body>; head membership is what crawlers require, which is why the
  # order check follows. That order check pins og:title and nothing else —
  # the other four ride along because the five ship as one contiguous block
  # a reviewer reads in a single hunk, not because anything here proves
  # where they sit. There is no og:image assertion because no image ships:
  # hosting one needs a wider SITE_KEY on the deploy role and a second
  # upload.
  assert_present "$HTML" '<meta property="og:title" content="fucking ship it">' 'index.html has the og:title meta'
  assert_present "$HTML" '<meta property="og:type" content="website">' 'index.html has the og:type meta'
  assert_present "$HTML" '<meta property="og:url" content="https://fuckingshipit.com/">' 'index.html has the og:url meta'
  assert_present "$HTML" '<meta property="og:description" content="fucking ship it">' 'index.html has the og:description meta'
  assert_present "$HTML" '<meta name="twitter:card" content="summary">' 'index.html has the twitter:card meta'
  assert_order "$HTML" '<meta property="og:title" content="fucking ship it">' '</head>' 'og:title sits inside <head>, where crawlers read it'

  # Regression guard for the original layout.haml defect: <body> was nested
  # inside <head>. The fix is well-formed nesting — head closes before body.
  assert_order "$HTML" '</head>' '<body>' 'index.html closes </head> before <body> opens'

  assert_count "$HTML" '<h1' 1 'index.html has exactly one <h1>'
  assert_present "$HTML" '<h1>fucking ship it</h1>' 'the <h1> text is "fucking ship it"'

  # All five media queries, verbatim — same rules and order as the
  # original stylesheet.
  assert_present "$HTML" '@media only screen and (max-width: 600px) { h1 { font-size: 2em; } }' 'media query max-width 600px -> 2em, verbatim'
  assert_present "$HTML" '@media only screen and (min-width: 600px) { h1 { font-size: 5em; } }' 'media query min-width 600px -> 5em, verbatim'
  assert_present "$HTML" '@media only screen and (min-width: 768px) { h1 { font-size: 6em; } }' 'media query min-width 768px -> 6em, verbatim'
  assert_present "$HTML" '@media only screen and (min-width: 992px) { h1 { font-size: 7em; } }' 'media query min-width 992px -> 7em, verbatim'
  assert_present "$HTML" '@media only screen and (min-width: 1200px) { h1 { font-size: 8em; } }' 'media query min-width 1200px -> 8em, verbatim'

  # Source order is load-bearing: at a viewport of exactly 600px BOTH the
  # max-width:600px and min-width:600px rules match, and the later rule wins.
  # max-width must come first so 5em wins at the boundary, same as today.
  assert_order "$HTML" '(max-width: 600px)' '(min-width: 600px)' 'max-width:600px rule appears before min-width:600px rule (600px boundary: 5em must win)'

  # The h1 and #footer rules, fixed strings verbatim from the original
  # stylesheet (including its double-space alignment in the h1 rule).
  assert_present "$HTML" 'font-family : "Helvetica";' 'the page sets Helvetica'
  assert_present "$HTML" 'text-align  : center;' 'h1 rule centers the heading'

  # font-family must be declared on `body`, not scoped to `h1`. Scoped to h1,
  # every other element — including the footer link — inherits the user
  # agent default instead, which renders as Times in Chromium. The original
  # stylesheet had this gap; the Twitter widget button supplied its own font
  # and hid it, so removing widgets.js made it visible.
  assert_order "$HTML" 'body {' 'font-family : "Helvetica";' 'font-family is declared on body so the whole page inherits it'
  assert_present "$HTML" '#footer' 'the #footer CSS rule exists'
  assert_present "$HTML" 'text-align: center;' 'the #footer rule centers the footer'

  # Footer anchor: label carried over; widget attributes dropped.
  # The href uses `hashtags=`, NOT the original `button_hashtag=`. The latter was
  # a parameter of Twitter's widgets.js, which read it client-side to build the
  # button. With the widget gone, X ignores it and opens an EMPTY composer.
  # `hashtags=` (comma-separated, no #) is the documented intent parameter
  # and prefills the hashtag.
  assert_present "$HTML" 'https://twitter.com/intent/tweet?hashtags=fuckingshipit' 'footer anchor href prefills the hashtag via hashtags='
  assert_absent "$HTML" 'button_hashtag' 'the widget-only button_hashtag param is gone'
  assert_present "$HTML" 'Tweet #fuckingshipit' 'footer anchor label is "Tweet #fuckingshipit"'

  # Zero external requests — nothing that can fetch anything.
  assert_absent "$HTML" '<script' 'index.html has no <script>'
  assert_absent "$HTML" '<link' 'index.html has no <link>'
  assert_absent "$HTML" '<img' 'index.html has no <img>'
  assert_absent "$HTML" 'src=' 'index.html has no src= attribute'
  assert_absent "$HTML" '@import' 'index.html has no CSS @import'
  assert_absent "$HTML" 'url(' 'index.html has no CSS url()'
  assert_absent "$HTML" '<iframe' 'index.html has no <iframe>'

  # Dead Twitter-widget attributes dropped: with the widget script gone
  # they can never activate, so keeping them would only mislead.
  assert_absent "$HTML" 'twitter-hashtag-button' 'widget class twitter-hashtag-button is gone'
  assert_absent "$HTML" 'data-url' 'widget attribute data-url is gone'
  assert_absent "$HTML" 'data-dnt' 'widget attribute data-dnt is gone'
  assert_absent "$HTML" 'platform.twitter.com' 'no reference to platform.twitter.com'

  # Google Analytics fully removed.
  assert_absent "$HTML" 'UA-36836831-1' 'Google Analytics tracking id is gone'
  assert_absent "$HTML" 'google-analytics' 'no reference to google-analytics'
  assert_absent "$HTML" '_gaq' 'no _gaq analytics queue'

  # HTML validity via tidy when installed; only exit 2 (errors) fails —
  # exit 1 (warnings) passes. Skipped, stated plainly, when not installed.
  if command -v tidy >/dev/null 2>&1; then
    if [ ! -f "$HTML" ]; then
      fail 'index.html has no tidy errors' "$HTML does not exist"
    else
      tidy -q -e "$HTML" >/dev/null 2>&1
      if [ $? -eq 2 ]; then
        fail 'index.html has no tidy errors' 'tidy exit 2 — run: tidy -q -e index.html'
      else
        pass 'index.html has no tidy errors (warnings allowed)'
      fi
    fi
  else
    echo "SKIP: tidy not installed — HTML validity not checked"
  fi
}

# ---------------------------------------------------------------------------
slice_2() { # the Sinatra app is deleted
  echo "--- Slice 2: Sinatra app deleted ---"

  assert_gone server.rb 'server.rb is deleted'
  assert_gone config.ru 'config.ru is deleted'
  assert_gone Procfile 'Procfile is deleted'
  assert_gone Gemfile 'Gemfile is deleted'
  assert_gone Gemfile.lock 'Gemfile.lock is deleted'
  assert_gone .ruby-version '.ruby-version is deleted'
  assert_gone newrelic.yml 'newrelic.yml is deleted'
  assert_gone lib 'lib/ is deleted'
  assert_gone views 'views/ is deleted'

  # .gitignore must not list /log/ or .bundle once the Sinatra app is
  # gone; deleting the whole file also satisfies that.
  if [ ! -e .gitignore ]; then
    pass '.gitignore no longer lists /log/ or .bundle (file deleted)'
  elif grep -qF -- '/log/' .gitignore || grep -qF -- '.bundle' .gitignore; then
    fail '.gitignore no longer lists /log/ or .bundle' 'dead entry still present'
  else
    pass '.gitignore no longer lists /log/ or .bundle'
  fi
}

# ---------------------------------------------------------------------------
slice_3() { # provision.sh — correct on paper, no AWS access needed
  echo "--- Slice 3: provision.sh ---"

  if [ -f provision.sh ] && bash -n provision.sh 2>/dev/null; then
    pass 'provision.sh parses (bash -n)'
  else
    fail 'provision.sh parses (bash -n)' 'provision.sh missing or has syntax errors'
  fi

  # The BASH_SOURCE guard makes sourcing define-only: functions load,
  # main never runs, no AWS call happens. If sourcing executed main, the
  # sts fail-fast would exit non-zero and this assertion would fail.
  if bash -c 'source ./provision.sh' >/dev/null 2>&1; then
    pass 'provision.sh is sourceable without executing main (BASH_SOURCE guard)'
  else
    fail 'provision.sh is sourceable without executing main (BASH_SOURCE guard)' 'provision.sh missing, or sourcing it runs main'
  fi

  # DO NOT "simplify" these two assertions away. They encode the
  # trailing-dot bug:
  # ACM returns ResourceRecord.Name fully qualified WITH a trailing dot
  # ("_abc123.fuckingshipit.com."), so stripping ".fuckingshipit.com"
  # alone does not match — the suffix is not at the end of the string.
  # strip_acm_name must strip the trailing dot FIRST, then the suffix.
  # Getting this wrong rebuilds "_abc123.fuckingshipit.com.fuckingshipit.com"
  # at Namecheap and hangs ACM validation for 72 hours with no useful error.
  assert_strip '_abc123.fuckingshipit.com.' '_abc123' 'strip_acm_name: apex validation name (trailing dot) -> _abc123'
  assert_strip '_def456.www.fuckingshipit.com.' '_def456.www' 'strip_acm_name: www validation name (trailing dot) -> _def456.www'

  # provision.sh reads every AWS response through jq, so a missing jq is a
  # broken deploy, not a test worth skipping.
  local jq_desc='jq is installed (provision.sh parses AWS responses with it)'
  if command -v jq >/dev/null 2>&1; then
    pass "$jq_desc"
  else
    fail "$jq_desc" 'not on PATH — install it: brew install jq'
  fi

  # One rejecting scenario per drift check below. Deleting any single
  # require_* line from provision.sh must turn a test red; a check with no
  # scenario is a check that can be removed unnoticed.
  assert_provision_rejects bucket_wrong_region ensure_bucket \
    "bucket fuckingshipit-com is in 'us-west-2', expected 'us-east-1'" \
    'ensure_bucket rejects a reused bucket in the wrong region'
  # The healthy bucket answers with LocationConstraint: null, the shape
  # us-east-1 actually returns — so this also covers the normalization.
  assert_provision_accepts bucket_healthy ensure_bucket 'already exists — reusing' \
    'ensure_bucket accepts a reused us-east-1 bucket (LocationConstraint: null)'

  assert_provision_rejects oac_wrong_type ensure_oac \
    "OriginAccessControlOriginType is 'mediastore', expected 's3'" \
    'ensure_oac rejects a reused OAC that no longer targets S3'
  assert_provision_rejects oac_wrong_signing ensure_oac \
    "SigningBehavior is 'never', expected 'always'" \
    'ensure_oac rejects a reused OAC that no longer signs requests'
  assert_provision_rejects oac_wrong_protocol ensure_oac \
    "SigningProtocol is 'sigv2', expected 'sigv4'" \
    'ensure_oac rejects a reused OAC signing with the wrong protocol'
  assert_provision_accepts oac_healthy ensure_oac 'Reusing origin access control' \
    'ensure_oac accepts a compatible reused OAC'

  assert_provision_rejects distribution_disabled verify_distribution_settings \
    "Enabled is 'DISABLED', expected 'ENABLED'" \
    'distribution drift check rejects a disabled distribution'
  assert_provision_rejects distribution_wrong_root_object verify_distribution_settings \
    "DefaultRootObject is 'home.html', expected 'index.html'" \
    'distribution drift check rejects a changed root object'
  assert_provision_rejects distribution_plaintext verify_distribution_settings \
    "ViewerProtocolPolicy is 'allow-all', expected 'redirect-to-https'" \
    'distribution drift check rejects plaintext HTTP'
  assert_provision_rejects distribution_old_tls verify_distribution_settings \
    "MinimumProtocolVersion is 'TLSv1', expected 'TLSv1.2_2021'" \
    'distribution drift check rejects a downgraded TLS floor'
  assert_provision_rejects distribution_wrong_ssl_method verify_distribution_settings \
    "SSLSupportMethod is 'vip', expected 'sni-only'" \
    'distribution drift check rejects a changed SSL support method'
  assert_provision_rejects distribution_headers_detached verify_distribution_settings \
    "ResponseHeadersPolicyId is 'DETACHED', expected 'EHEADERS123'" \
    'distribution drift check rejects a detached security-headers policy'
  assert_provision_rejects distribution_cache_policy_swapped verify_distribution_settings \
    "CachePolicyId is 'EOTHERCACHE', expected 'ECACHE123'" \
    'distribution drift check rejects a swapped cache policy'
  assert_provision_rejects distribution_compress_off verify_distribution_settings \
    "Compress is 'DISABLED', expected 'ENABLED'" \
    'distribution drift check rejects compression turned off'
  # Also the redaction guard: the printed ARN must carry a masked account
  # ID, so drift output stays safe to paste into a CI log or an issue.
  assert_provision_rejects distribution_wrong_cert verify_distribution_settings \
    "ACMCertificateArn is 'arn:aws:acm:us-east-1:************:certificate/other'" \
    'distribution drift check rejects a swapped certificate, account ID masked'
  assert_provision_rejects distribution_missing_alias verify_distribution_settings \
    "Aliases is 'fuckingshipit.com', expected 'fuckingshipit.com,www.fuckingshipit.com'" \
    'distribution drift check rejects a dropped alias'
  assert_provision_rejects distribution_no_custom_errors verify_distribution_settings \
    "CustomErrorResponses is 'NONE'" \
    'distribution drift check rejects removed custom error responses'
  assert_provision_rejects distribution_extra_cache_behavior verify_distribution_settings \
    "CacheBehaviorCount is '1', expected '0'" \
    'distribution drift check rejects an added cache behavior'
  assert_provision_rejects distribution_two_origins verify_distribution_settings \
    "OriginCount is '2', expected '1'" \
    'distribution drift check rejects a second origin'
  assert_provision_rejects distribution_wrong_origin_id verify_distribution_settings \
    "OriginId is 'other-origin-id', expected 's3-fuckingshipit-com'" \
    'distribution drift check rejects a renamed origin'
  assert_provision_rejects distribution_wrong_origin verify_distribution_settings \
    "OriginDomainName is 'other-bucket.s3.us-east-1.amazonaws.com'" \
    'distribution drift check rejects a repointed origin'
  assert_provision_rejects distribution_origin_path verify_distribution_settings \
    "OriginPath is '/staging', expected 'NONE'" \
    'distribution drift check rejects an origin path prefix'
  assert_provision_rejects distribution_oac_detached verify_distribution_settings \
    "OriginAccessControlId is 'DETACHED', expected 'EOAC123'" \
    'distribution drift check rejects a detached origin access control'
  assert_provision_rejects distribution_legacy_oai verify_distribution_settings \
    "OriginAccessIdentity is 'origin-access-identity/cloudfront/E2LEGACY'" \
    'distribution drift check rejects a legacy origin access identity'
  assert_provision_rejects distribution_custom_origin verify_distribution_settings \
    "CustomOriginConfig is 'PRESENT', expected 'ABSENT'" \
    'distribution drift check rejects an origin converted to a custom origin'
  assert_provision_rejects distribution_wrong_target verify_distribution_settings \
    "TargetOriginId is 'other-origin', expected 's3-fuckingshipit-com'" \
    'distribution drift check rejects a repointed default behavior'
  # Regression guard for the row-splitting hole: this config is drifted AND
  # carries a newline in an earlier value. Reading the response as one
  # tab-separated row accepted it; reading each field on its own rejects it.
  assert_provision_rejects distribution_newline_in_value verify_distribution_settings \
    "DefaultRootObject is 'index.html" \
    'distribution drift check rejects a value carrying a newline'
  assert_provision_accepts distribution_healthy verify_distribution_settings '' \
    'distribution drift check accepts the expected serving path'
}

# ---------------------------------------------------------------------------
slice_4() { # deploy.sh — refuses to run without deploy.env
  echo "--- Slice 4: deploy.sh ---"

  if [ -f deploy.sh ] && bash -n deploy.sh 2>/dev/null; then
    pass 'deploy.sh parses (bash -n)'
  else
    fail 'deploy.sh parses (bash -n)' 'deploy.sh missing or has syntax errors'
  fi

  # Run deploy.sh in a scratch dir that has no deploy.env, so this stays
  # true even once provisioning has written deploy.env to the repo root.
  # It must refuse — non-zero exit and a message naming deploy.env —
  # before any AWS call.
  local tmp out rc
  tmp=$(mktemp -d)
  cp deploy.sh "$tmp/deploy.sh" 2>/dev/null
  out=$(cd "$tmp" && bash ./deploy.sh 2>&1)
  rc=$?
  command rm -rf "$tmp"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'deploy.env'; then
    pass 'deploy.sh refuses without deploy.env (non-zero exit, message names deploy.env)'
  else
    fail 'deploy.sh refuses without deploy.env (non-zero exit, message names deploy.env)' "exit=$rc, output: ${out:-<none>}"
  fi

  # deploy.env is meant to be committed once provisioning has run — it is
  # how deploy.sh gets its IDs on a fresh clone — so a present one is
  # validated, never forbidden. EVERY copy that could ship is checked:
  # the working tree AND the staged (index) copy, not HEAD's. A malformed
  # file staged but not yet committed is precisely the sequence that
  # ships green and then breaks a fresh clone, and a fixed working tree
  # can still hide a stale malformed copy in the index. The contract
  # mirrors deploy.sh's in full (deploy_env_violations): a well-shaped
  # file missing a key breaks a fresh clone just the same.
  local env_desc='deploy.env about to ship satisfies deploy.sh contract'
  local env_checked='' problems
  if [ -f deploy.env ]; then
    env_checked=yes
    problems=$(deploy_env_violations < deploy.env)
    if [ -n "$problems" ]; then
      fail "$env_desc" "working tree copy: ${problems%; }"
      return
    fi
  fi
  if git cat-file -e :deploy.env 2>/dev/null; then
    env_checked=yes
    problems=$(git cat-file -p :deploy.env 2>/dev/null | deploy_env_violations)
    if [ -n "$problems" ]; then
      fail "$env_desc" "index copy: ${problems%; }"
      return
    fi
  fi
  if [ -n "$env_checked" ]; then
    pass "$env_desc"
  else
    pass 'no deploy.env on disk or in the index (nothing to validate)'
  fi
}

# ---------------------------------------------------------------------------
slice_5() { # continuous deployment — the workflow and the role it assumes
  echo "--- Slice 5: continuous deployment ---"

  if [ -f provision-ci.sh ] && bash -n provision-ci.sh 2>/dev/null; then
    pass 'provision-ci.sh parses (bash -n)'
  else
    fail 'provision-ci.sh parses (bash -n)' 'provision-ci.sh missing or has syntax errors'
  fi

  # Same guard, same reason as provision.sh: sourcing must define functions
  # and reach no AWS call, or this assertion would need credentials to pass.
  if bash -c 'source ./provision-ci.sh' >/dev/null 2>&1; then
    pass 'provision-ci.sh is sourceable without executing main (BASH_SOURCE guard)'
  else
    fail 'provision-ci.sh is sourceable without executing main (BASH_SOURCE guard)' 'provision-ci.sh missing, or sourcing it runs main'
  fi

  local wf=.github/workflows/deploy.yml
  assert_present "$wf" 'branches: [master]' 'the workflow triggers on pushes to master'
  assert_present "$wf" 'id-token: write' 'the deploy job requests an OIDC identity token'
  assert_present "$wf" './check.sh' 'the workflow runs this acceptance gate before deploying'
  assert_present "$wf" './deploy.sh' 'the workflow deploys via deploy.sh, not its own aws commands'

  # jq is preinstalled on the runner, so omitting it would still pass —
  # until the day it does not, and 28 assertions fail for a reason no one
  # would look for in a workflow file. The gate names what it needs.
  assert_present "$wf" 'install -y tidy jq' 'the workflow installs the tools check.sh needs (tidy, jq)'

  # OIDC exists so a public repo never holds a long-lived key. A workflow
  # that reintroduced one would still deploy — green, and a regression.
  assert_absent "$wf" 'aws-access-key-id' 'the workflow uses no long-lived AWS access key'

  # deploy.env is gitignored, so CI generates it from secrets. That
  # generated file must satisfy the same contract slice 4 enforces on a
  # committed one: a malformed one fails the deploy AFTER this gate has
  # already gone green. The literal below is asserted to be the workflow's
  # own format string, then rendered and validated — so a drifted workflow
  # fails the first assertion and a wrong format fails the second.
  local fmt='BUCKET=%s\nDISTRIBUTION_ID=%s\nDISTRIBUTION_DOMAIN=%s\n'
  assert_present "$wf" "printf '$fmt'" 'the workflow writes deploy.env with the expected format string'

  local problems
  # shellcheck disable=SC2059
  # $fmt IS the format string under test — the whole point is to render
  # the workflow's own template, not to print it literally.
  problems=$(printf "$fmt" sample-bucket E1SAMPLE d1sample.cloudfront.net | deploy_env_violations)
  if [ -z "$problems" ]; then
    pass 'the deploy.env that format produces satisfies deploy.sh contract'
  else
    fail 'the deploy.env that format produces satisfies deploy.sh contract' "${problems%; }"
  fi
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
  1) slice_1 ;;
  2) slice_2 ;;
  3) slice_3 ;;
  4) slice_4 ;;
  5) slice_5 ;;
  all)
    slice_1
    slice_2
    slice_3
    slice_4
    slice_5
    ;;
  *)
    echo "usage: ./check.sh [1|2|3|4|5]" >&2
    exit 2
    ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo OK
  exit 0
fi
exit 1
