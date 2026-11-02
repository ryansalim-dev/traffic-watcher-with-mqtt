#!/usr/bin/env bash
# Deploys a built site directory (the landing page plus appcast.xml) to Cloudflare Pages, which
# serves https://wiretide.app. Creates the Pages project the first time.
#
#   scripts/deploy-site.sh <dir>
#
# Environment:
#   CLOUDFLARE_API_TOKEN   token with Account > Cloudflare Pages > Edit
#   CLOUDFLARE_ACCOUNT_ID  Cloudflare account ID
#   PAGES_PROJECT          Pages project name (default: wiretide)
set -euo pipefail

DIR=${1:?usage: deploy-site.sh <dir>}
PROJECT=${PAGES_PROJECT:-wiretide}
WRANGLER=(npx --yes wrangler@4.149.0)

missing=()
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || missing+=(CLOUDFLARE_API_TOKEN)
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || missing+=(CLOUDFLARE_ACCOUNT_ID)
if (( ${#missing[@]} )); then
  echo "::error::Missing Cloudflare settings: ${missing[*]}. Add them as repository secrets."
  exit 1
fi
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

# Upload a clean copy: no git metadata, and no GitHub Pages CNAME file.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
tar -C "$DIR" --exclude=.git --exclude=CNAME -cf - . | tar -C "$STAGE" -xf -

status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$PROJECT")
case "$status" in
  200) ;;
  404)
    echo "Creating Pages project $PROJECT"
    "${WRANGLER[@]}" pages project create "$PROJECT" --production-branch main
    ;;
  *)
    echo "::error::Cloudflare answered HTTP $status when looking up Pages project $PROJECT. Check the token's permissions and the account ID."
    exit 1
    ;;
esac

"${WRANGLER[@]}" pages deploy "$STAGE" --project-name "$PROJECT" --branch main \
  --commit-hash "${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}" --commit-dirty=true
