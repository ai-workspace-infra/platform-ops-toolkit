#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloudflare Pages 前端控制台部署脚本
# -----------------------------------------------------------------------------

PORTAL_DIR="${PORTAL_DIR:?PORTAL_DIR must point to a checked-out portal repository}"
CLOUDFLARE_ENV="${CLOUDFLARE_ENV:-uat}"
PAGES_PROJECT="${PAGES_PROJECT_NAME:-ai-workspace-portal-${CLOUDFLARE_ENV}}"
PAGES_BRANCH="${PAGES_BRANCH:-${CLOUDFLARE_ENV}}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] Deploying portal frontend to project: ${PAGES_PROJECT}..."

test -f "${PORTAL_DIR}/package.json"
pushd "${PORTAL_DIR}" > /dev/null
corepack enable
yarn install --immutable
yarn build:static-dashboard
# Ensure the Cloudflare Pages project exists before deploying
yarn exec wrangler pages project create "${PAGES_PROJECT}" --production-branch="${PAGES_BRANCH}" || true
yarn exec wrangler pages deploy static-dashboard/out --project-name="${PAGES_PROJECT}" --branch="${PAGES_BRANCH}"
popd > /dev/null

echo "==> [Cloudflare Pages ${CLOUDFLARE_ENV}] Portal deployment finished."
