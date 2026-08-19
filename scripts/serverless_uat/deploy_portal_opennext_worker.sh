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

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:-}"
STATIC_CDN_URL=""
if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
  STATIC_CDN_URL="$(jq -r '.spec.cloudflare.static_cdn_url // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
fi

test -f "${PORTAL_DIR}/package.json"
pushd "${PORTAL_DIR}" > /dev/null
corepack enable
yarn install --immutable
env -u CLOUDFLARE_ENV \
  PORTAL_DEPLOYMENT_ENV="${CLOUDFLARE_ENV}" \
  RUNTIME_ENV="${CLOUDFLARE_ENV}" \
  NEXT_PUBLIC_STATIC_CDN_URL="${STATIC_CDN_URL}" \
  yarn "build:ssr:${PORTAL_SSR_BOUNDARY}"
env -u CLOUDFLARE_ENV yarn exec wrangler deploy \
  --config ".edge-build/${PORTAL_SSR_BOUNDARY}/wrangler.jsonc"
# When a static CDN is declared the boundary emits absolute
# <cdn>/_edge/<boundary>/_next/... asset URLs, so the same assets must also be
# published to the CDN (Cloudflare Pages).  Hand them to the caller, which
# merges every boundary into the single Pages deployment.
if [[ -n "${EDGE_ASSETS_OUT:-}" ]]; then
  node scripts/collect-edge-assets.mjs --out "${EDGE_ASSETS_OUT}" --boundary "${PORTAL_SSR_BOUNDARY}"
fi
popd > /dev/null
