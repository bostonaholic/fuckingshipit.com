# fuckingshipit.com

## What this is

One static page served from a private S3 bucket behind CloudFront. No
server, no runtime, nothing to patch. The repo's files:

- `index.html` — the whole site, CSS inline, zero external requests
- `check.sh` — pre-deploy grep assertions against `index.html`
- `provision.sh` — one-time AWS setup (bucket, ACM cert, CloudFront)
- `deploy.sh` — repeatable upload + edge cache invalidation
- `deploy.env` — IDs written by `provision.sh` (appears after the first
  provision run), read by `deploy.sh`
- `README.md` — this runbook

## Prerequisites

- AWS CLI v2, authenticated via `aws login`
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

- `./check.sh` exits 0.

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
- `curl -s "https://fuckingshipit-com.s3.us-east-1.amazonaws.com/index.html"`
  returns `AccessDenied` (the bucket is private; only CloudFront reads it).

Manual only:

- Rendering at each breakpoint (600/768/992/1200px): heading centered
  and resizing, footer link centered.
- A real phone — expect the 2em heading; that is the intentional
  viewport-fix outcome (design decision 2), not a bug.
- Apex and `www` over HTTPS after the DNS edits propagate.
