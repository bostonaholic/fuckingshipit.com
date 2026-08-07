#!/usr/bin/env bash
# check.sh — acceptance tests for the static-site-s3-cloudfront change.
#
# Usage:
#   ./check.sh        run every slice's assertions (the full acceptance gate)
#   ./check.sh 1      run one slice's assertions in isolation (1, 2, 3, or 4)
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

# ---------------------------------------------------------------------------
slice_1() { # index.html — the static page, verifiable locally
  echo "--- Slice 1: the static page (index.html) ---"

  assert_present "$HTML" '<!DOCTYPE html>' 'index.html declares <!DOCTYPE html>'
  assert_present "$HTML" '<meta charset="utf-8">' 'index.html declares utf-8 charset'
  assert_present "$HTML" '<meta name="viewport" content="width=device-width, initial-scale=1">' 'index.html has the viewport meta'

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
  assert_present "$HTML" 'font-family : "Helvetica";' 'h1 rule sets Helvetica'
  assert_present "$HTML" 'text-align  : center;' 'h1 rule centers the heading'
  assert_present "$HTML" '#footer' 'the #footer CSS rule exists'
  assert_present "$HTML" 'text-align: center;' 'the #footer rule centers the footer'

  # Footer anchor: href and label carried over; widget attributes dropped.
  assert_present "$HTML" 'https://twitter.com/intent/tweet?button_hashtag=fuckingshipit' 'footer anchor href is the tweet intent URL'
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
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
  1) slice_1 ;;
  2) slice_2 ;;
  3) slice_3 ;;
  4) slice_4 ;;
  all)
    slice_1
    slice_2
    slice_3
    slice_4
    ;;
  *)
    echo "usage: ./check.sh [1|2|3|4]" >&2
    exit 2
    ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo OK
  exit 0
fi
exit 1
