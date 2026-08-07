#!/usr/bin/env bash
# provision-ci.sh — one-time AWS setup for continuous deployment: the
# GitHub OIDC identity provider and the IAM role GitHub Actions assumes
# in order to run deploy.sh.
#
# Separate from provision.sh because it provisions a different thing on a
# different schedule. provision.sh builds the site's infrastructure and
# blocks up to ~40 minutes on human DNS work; this grants a CI principal
# the exact two permissions deploy.sh needs and finishes in seconds.
#
# Rerunnable by design: every resource has a stable lookup key, and both
# policies are rewritten on every run, so a trust policy or permission set
# edited in the console is corrected rather than inherited.
#
# Takes no arguments. Fails fast on an expired AWS session.
set -euo pipefail

DOMAIN=fuckingshipit.com
BUCKET=fuckingshipit-com
# The only object deploy.sh ever uploads. Widen to /* if the site grows
# assets — a PutObject denial surfaces as a failed CI run, not a partial
# deploy, but it is still an outage of the pipeline.
SITE_KEY=index.html
GITHUB_ORG=bostonaholic
GITHUB_REPO=fuckingshipit.com
BRANCH=master
ROLE_NAME=fuckingshipit-com-github-deploy
POLICY_NAME=deploy-site
OIDC_HOST=token.actions.githubusercontent.com

require_auth() {
  if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo "ERROR: AWS session is expired or unauthenticated. Run: aws login" >&2
    exit 1
  fi
}

# The provider ARN is fully determined by the account and the host, so
# get-open-id-connect-provider is an exact existence check — no list scan,
# no name matching. One provider serves every repo in the account; this
# only ever adds the one GitHub needs.
ensure_oidc_provider() {
  local arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1; then
    echo "Reusing OIDC provider ${OIDC_HOST}."
    return
  fi
  echo "Creating OIDC provider ${OIDC_HOST}..."
  # No --thumbprint-list on purpose. IAM validates this provider against
  # its own library of trusted root CAs, so there is no certificate
  # fingerprint to pin here and none to rotate when GitHub renews.
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com >/dev/null
}

# Same alias lookup provision.sh uses, for the same reason: aliases are
# globally unique, so the distribution id never has to be hardcoded in two
# places and can never drift out of sync with the live one.
resolve_distribution() {
  DISTRIBUTION_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(not_null(Aliases.Items, \`[]\`), '${DOMAIN}')] | [0].Id" \
    --output text)
  if [ -z "$DISTRIBUTION_ID" ] || [ "$DISTRIBUTION_ID" = "None" ]; then
    echo "ERROR: no CloudFront distribution carries the alias ${DOMAIN}." >&2
    echo "Run ./provision.sh first — the role's invalidation permission is scoped to that distribution." >&2
    exit 1
  fi
  DISTRIBUTION_DOMAIN=$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" \
    --query Distribution.DomainName --output text)
}

# The sub condition is what keeps this role from being a hole in a public
# repo: it names the org, the repo, AND the branch, so a fork, a pull
# request, or a feature branch produces a token that cannot assume it.
# Rewritten on every run so a condition loosened in the console does not
# survive.
ensure_role() {
  local trust
  trust=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOST}:aud": "sts.amazonaws.com",
          "${OIDC_HOST}:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${BRANCH}"
        }
      }
    }
  ]
}
EOF
)
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role ${ROLE_NAME} already exists — rewriting its trust policy."
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
      --policy-document "$trust"
  else
    echo "Creating role ${ROLE_NAME}..."
    aws iam create-role --role-name "$ROLE_NAME" \
      --description "GitHub Actions deploys ${DOMAIN} from ${BRANCH}" \
      --assume-role-policy-document "$trust" >/dev/null
  fi
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
}

# Exactly what deploy.sh does, nothing more: one PutObject on one key, one
# invalidation on one distribution. sts:GetCallerIdentity (deploy.sh's
# session check) needs no permission — every principal may call it.
# Inline rather than managed so the permissions cannot outlive the role.
attach_deploy_policy() {
  local policy
  policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PutSiteObject",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BUCKET}/${SITE_KEY}"
    },
    {
      "Sid": "InvalidateEdgeCache",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DISTRIBUTION_ID}"
    }
  ]
}
EOF
)
  aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" --policy-document "$policy"
  echo "Wrote inline policy ${POLICY_NAME} (PutObject on ${SITE_KEY}, CreateInvalidation on ${DISTRIBUTION_ID})."
}

# The IDs are not secret, but there is no reason to publish internal
# resource ids from a public repo — the same reasoning that gitignores
# deploy.env. Secrets, not variables, so they stay out of the logs too.
print_next_steps() {
  echo ""
  echo "Role ready: ${ROLE_ARN}"
  echo ""
  echo "Set the four repository secrets .github/workflows/deploy.yml reads:"
  echo "  gh secret set AWS_DEPLOY_ROLE_ARN --body '${ROLE_ARN}'"
  echo "  gh secret set DEPLOY_BUCKET --body '${BUCKET}'"
  echo "  gh secret set DEPLOY_DISTRIBUTION_ID --body '${DISTRIBUTION_ID}'"
  echo "  gh secret set DEPLOY_DISTRIBUTION_DOMAIN --body '${DISTRIBUTION_DOMAIN}'"
  echo ""
  echo "After that, every push to ${BRANCH} deploys."
}

main() {
  require_auth
  ensure_oidc_provider
  resolve_distribution
  ensure_role
  attach_deploy_policy
  print_next_steps
}

# Source guard, same as provision.sh: `source ./provision-ci.sh` defines
# functions and executes nothing, so check.sh can load this file without
# an AWS session.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
