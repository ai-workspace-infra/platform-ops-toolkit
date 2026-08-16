#!/usr/bin/env bash
set -euo pipefail

# Deploy the portal Server Runtime to the UAT OpenNext/Cloudflare Worker target.
PORTAL_DIR="${PORTAL_DIR:?PORTAL_DIR must point to a checked-out portal repository}"
CLOUDFLARE_ENV="${CLOUDFLARE_ENV:-uat}"
PORTAL_SSR_BOUNDARY="${PORTAL_SSR_BOUNDARY:-public}"

case "${PORTAL_SSR_BOUNDARY}" in
  public|content|auth|console|workspace) ;;
  *)
    echo "PORTAL_SSR_BOUNDARY must be public, content, auth, console, or workspace" >&2
    exit 2
    ;;
esac

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

test -f "${PORTAL_DIR}/package.json"
pushd "${PORTAL_DIR}" > /dev/null
corepack enable
yarn install --immutable
yarn "build:ssr:${PORTAL_SSR_BOUNDARY}"
yarn exec wrangler deploy \
  --config ".edge-build/${PORTAL_SSR_BOUNDARY}/wrangler.jsonc" \
  --env "${CLOUDFLARE_ENV}"
popd > /dev/null
