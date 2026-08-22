# fuckingshipit.com

## What this is

One static page served from a private S3 bucket behind CloudFront. No
server, no runtime, nothing to patch. The repo's files:

- `index.html` — the whole site, CSS inline, zero external requests
- `check.sh` — pre-deploy grep assertions against `index.html`
- `provision.sh` — one-time AWS setup (bucket, ACM cert, CloudFront)
- `provision-ci.sh` — one-time AWS setup for CI (GitHub OIDC provider and
  the IAM role GitHub Actions assumes)
- `deploy.sh` — repeatable upload + edge cache invalidation
- `.github/workflows/deploy.yml` — runs `check.sh` then `deploy.sh` on
  every push to `master`
- `deploy.env` — IDs written by `provision.sh` (appears after the first
  provision run), read by `deploy.sh`. Must stay exactly the three plain
  `KEY=value` lines `provision.sh` writes — no comments, no quotes, no
  extra lines — because `deploy.sh` rejects anything else. If a hand-edit
  breaks it, re-run `./provision.sh` to regenerate it
- `README.md` — this runbook

## Prerequisites

- AWS CLI v2, authenticated via `aws login`
- `jq` — `provision.sh` reads every AWS response through it
- Access to Namecheap DNS for `fuckingshipit.com`

## Rollout

1. `aws login` — confirm with `aws sts get-caller-identity`.
2. `./provision.sh` — creates the bucket, requests the certificate, and
   prints the validation CNAME table. It then waits for ACM (up to
   ~40 min); if it times out before you paste DNS, it exits non-zero and
   re-prints the pairs — that is the expected re-run path, not a failure.
3. At Namecheap, add both printed validation CNAMEs, pasting Host and
   Value **verbatim** — the script has already made Host Namecheap-ready;
   apply no rule of your own.
4. Re-run `./provision.sh` — reuses the bucket and cert, waits for
   `ISSUED`, creates the OAC and distribution, attaches the bucket
   policy, writes `deploy.env`, and prints the final DNS table.

   If validation stays stuck even though you pasted the records, the
   records are probably wrong, not slow: Namecheap's UI can silently
   mangle pasted values. Diff the printed Host/Value pairs against what
   Namecheap actually saved and fix any mismatch — a blind re-run waits
   on the same broken records.

   A re-run can also stop on a resource that already exists but no longer
   matches what the script expects — a bucket in the wrong region, an OAC
   that stopped signing, a distribution disabled or repointed in the
   console. That is the expected halt, not a failure: reuse is checked,
   never assumed. The `ERROR:` line names the exact setting and both
   values, so fix that one setting in the AWS console and re-run. The
   script never repairs live config on its own — an unexpected config is
   a human decision.
5. Load the IDs `provision.sh` wrote, then wait for the distribution to
   finish deploying. Run this in the repo root — every later command
   that uses `$DISTRIBUTION_ID` or `$DISTRIBUTION_DOMAIN` needs the
   `source` first (in each new terminal):

   ```
   source deploy.env
   aws cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID"
   ```

6. `./deploy.sh`, then run the post-deploy curls from the verification
   checklist below against `$DISTRIBUTION_DOMAIN`.
7. Final DNS edits at Namecheap:
   - DELETE the apex URL Forward (it conflicts with ALIAS; both claim `@`)
   - DELETE the `www` A record pointing at `0.0.0.0`
   - ADD `@ ALIAS <dist>.cloudfront.net`
   - ADD `www CNAME <dist>.cloudfront.net`
8. After propagation (minutes to hours is normal):
   `curl -sI https://fuckingshipit.com/` and
   `curl -sI https://www.fuckingshipit.com/` both return `200`.

## Continuous deployment

Every push to `master` runs `check.sh` and then `deploy.sh` — the same two
commands as by hand, on GitHub's runner instead of a laptop. No AWS keys
are stored anywhere: the workflow exchanges a short-lived GitHub OIDC
token for an IAM role that may do exactly two things, upload
`index.html` and invalidate the cache.

One-time setup, after `provision.sh` has created the distribution:

1. `./provision-ci.sh` — creates the OIDC provider, the role, and its
   inline policy, then prints the four `gh secret set` commands with the
   real values filled in. Rerunnable; it rewrites both policies each time,
   so console drift is corrected rather than inherited.
2. Run those four commands. The workflow reads `AWS_DEPLOY_ROLE_ARN`,
   `DEPLOY_BUCKET`, `DEPLOY_DISTRIBUTION_ID`, and
   `DEPLOY_DISTRIBUTION_DOMAIN`. They are repository *secrets*, not
   variables, for the same reason `deploy.env` is gitignored — the repo is
   public and internal resource ids need not be published. One visible
   effect: Actions masks them, so the deploy log ends
   `Deployed. Site: https://***/`.

The role's trust policy names the org, the repo, **and** `refs/heads/master`,
so a fork or a feature branch cannot assume it. The permission to upload is
scoped to the single key `index.html`; if the site ever grows assets, widen
`SITE_KEY` in `provision-ci.sh` and re-run it.

Running `./deploy.sh` by hand still works and remains the break-glass path
when Actions is down. `Actions → deploy → Run workflow` redeploys `master`
without an empty commit.

## DNS table

`./provision.sh` prints the real values — these rows are placeholders.

| Type  | Host              | Value                        |
| ----- | ----------------- | ---------------------------- |
| CNAME | `_<placeholder>`     | `_<placeholder>.acm-validations.aws.` |
| CNAME | `_<placeholder>.www` | `_<placeholder>.acm-validations.aws.` |
| ALIAS | `@`               | `<dist>.cloudfront.net`      |
| CNAME | `www`             | `<dist>.cloudfront.net`      |

## Verification checklist

Pre-deploy:

- `./check.sh` exits 0. CI runs this too, and blocks the deploy if it
  fails, so a red gate never reaches S3.

Post-deploy, against `$DISTRIBUTION_DOMAIN` — run `source deploy.env` in
the repo root first, or the curls below hit an empty hostname:

- `curl -s -o /dev/null -w "%{http_code}" "https://$DISTRIBUTION_DOMAIN/"`
  returns `200`, and the body contains `fucking ship it`.
- `curl -s "https://$DISTRIBUTION_DOMAIN/a/b/c"` returns 200 with the
  same page (unknown paths rewrite to `index.html`).
- `curl -sI "http://$DISTRIBUTION_DOMAIN/"` returns `301` with an
  `https://` location.
- `curl -sI "https://$DISTRIBUTION_DOMAIN/"` shows
  `cache-control: public, max-age=300`.
- `curl -sI "https://$DISTRIBUTION_DOMAIN/"` shows
  `strict-transport-security` (plus `x-content-type-options` and
  `x-frame-options`) — proof the managed security headers policy is
  attached.
- `curl -s "https://fuckingshipit-com.s3.us-east-1.amazonaws.com/index.html"`
  returns `AccessDenied` (the bucket is private; only CloudFront reads it).
- `curl -s "https://$DISTRIBUTION_DOMAIN/" | grep -q 'og:title'` matches.
  Grepping one of the five link-preview tags is deliberate, not an
  oversight: all five ship inside the same `index.html` object, so one hit
  proves the whole block landed. `./check.sh` is what pins each tag.

Manual only:

- Rendering at each breakpoint (600/768/992/1200px): heading centered
  and resizing, footer link centered.
- A real phone — expect the 2em heading, not a bug: the viewport meta
  tag makes phones report their real width, so the `max-width: 600px`
  rule applies.
- Apex and `www` over HTTPS after the DNS edits propagate.
- Link previews: paste `https://fuckingshipit.com/` into Slack, an X
  compose box, and Facebook's Sharing Debugger. Expect a text card reading
  `fucking ship it`. A text-only card with no image is the pass — the site
  ships no `og:image`, so the debugger's warning about the missing image is
  a recorded choice, not a failure. Each platform caches what it scraped:
  the Sharing Debugger has a "Scrape Again" button, while Slack and X offer
  no such control, so paste a cache-busting `https://fuckingshipit.com/?1`
  to force a fresh fetch.
