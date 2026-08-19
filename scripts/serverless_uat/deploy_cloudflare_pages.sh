#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloudflare Pages 前端控制台部署脚本
# -----------------------------------------------------------------------------

PORTAL_DIR="${PORTAL_DIR:?PORTAL_DIR must point to a checked-out portal repository}"
CLOUDFLARE_ENV="${CLOUDFLARE_ENV:-uat}"
PAGES_PROJECT="${PAGES_PROJECT_NAME:-ai-workspace-portal-${CLOUDFLARE_ENV}}"
PAGES_BRANCH="${PAGES_BRANCH:-${CLOUDFLARE_ENV}}"
CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:-}"

STATIC_CDN_URL=""
SSR_BOUNDARIES=""
CONSOLE_HOST=""
# SSR entry points that live only on the console host and never carry a static
# file, so redirecting them away from the Pages hostname cannot shadow an asset.
SSR_ENTRY_PATHS=(login register email-verification logout panel dashboard)
if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
  if jq -e '.kind == "EdgeRoutingConfig"' "${CONFIG_FILE}" >/dev/null; then
    PAGES_PROJECT="$(jq -er '.spec.cloudflare.pages_project' "${CONFIG_FILE}")"
    PAGES_BRANCH="$(jq -er '.spec.cloudflare.pages_branch' "${CONFIG_FILE}")"
    STATIC_CDN_URL="$(jq -r '.spec.cloudflare.static_cdn_url // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    SSR_BOUNDARIES="$(jq -r '.spec.serverless.ssr[]?.id // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    CONSOLE_HOST="$(jq -r '.spec.serverless.console_host // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
  fi
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] Deploying portal frontend to project: ${PAGES_PROJECT}..."

test -f "${PORTAL_DIR}/package.json"
pushd "${PORTAL_DIR}" > /dev/null
corepack enable
yarn install --immutable
NEXT_PUBLIC_STATIC_CDN_URL="${STATIC_CDN_URL}" yarn build:static-dashboard

# The SSR boundaries build their client chunks against
# <static_cdn_url>/_edge/<boundary>, so the Pages deployment that backs the CDN
# has to carry those assets as well; otherwise every SSR page loads its HTML
# from the Worker and 404s every chunk against Pages.  EDGE_ASSETS_DIR holds the
# per-boundary output collected by deploy_portal_opennext_worker.sh.
if [[ -n "${STATIC_CDN_URL}" ]]; then
  if [[ -z "${EDGE_ASSETS_DIR:-}" || ! -d "${EDGE_ASSETS_DIR}/_edge" ]]; then
    echo "static_cdn_url is set (${STATIC_CDN_URL}) but no boundary assets were provided via EDGE_ASSETS_DIR; refusing to publish a Pages deployment that 404s every SSR chunk" >&2
    exit 1
  fi
  for boundary in ${SSR_BOUNDARIES}; do
    if [[ ! -d "${EDGE_ASSETS_DIR}/_edge/${boundary}" ]]; then
      echo "Missing edge assets for SSR boundary '${boundary}' in ${EDGE_ASSETS_DIR}/_edge" >&2
      exit 1
    fi
  done
  echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] Merging boundary assets from ${EDGE_ASSETS_DIR}/_edge..."
  mkdir -p static-dashboard/out/_edge
  cp -R "${EDGE_ASSETS_DIR}/_edge/." static-dashboard/out/_edge/
elif [[ -n "${EDGE_ASSETS_DIR:-}" && -d "${EDGE_ASSETS_DIR}/_edge" ]]; then
  echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] static_cdn_url is unset; boundary assets stay on the SSR Workers."
fi
# The Pages hostname serves the static marketing export plus the boundary
# assets; every SSR route only exists behind the console host.  A visitor who
# lands on the Pages hostname (or follows a relative link out of the static
# export) would otherwise get the static 404 page instead of the console, so
# hand those paths back to the console host.  Cloudflare evaluates redirects
# before assets, which is why the rules stay on SSR-only prefixes.
if [[ -n "${CONSOLE_HOST}" ]]; then
  echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] Redirecting SSR entry points to https://${CONSOLE_HOST}..."
  for entry in "${SSR_ENTRY_PATHS[@]}"; do
    printf '/%s https://%s/%s 302\n' "${entry}" "${CONSOLE_HOST}" "${entry}"
    printf '/%s/* https://%s/%s/:splat 302\n' "${entry}" "${CONSOLE_HOST}" "${entry}"
  done >> static-dashboard/out/_redirects
fi

# Pages deployments are environment-scoped.  Create the explicitly selected
# project once when a fresh Cloudflare account has not been provisioned yet;
# an existing project is reused without changing its configuration.
pages_projects="$(yarn exec wrangler pages project list)"
if ! printf '%s\n' "${pages_projects}" | grep -F -- "${PAGES_PROJECT}" >/dev/null; then
  echo "==> [Cloudflare Pages UAT] Creating missing Pages project: ${PAGES_PROJECT}..."
  yarn exec wrangler pages project create "${PAGES_PROJECT}" \
    --production-branch="${PAGES_BRANCH}"
fi
yarn exec wrangler pages deploy static-dashboard/out --project-name="${PAGES_PROJECT}" --branch="${PAGES_BRANCH}"
popd > /dev/null

echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] Portal deployment finished."
