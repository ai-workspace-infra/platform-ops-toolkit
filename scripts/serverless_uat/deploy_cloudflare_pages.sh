#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloudflare Pages 前端控制台部署脚本
# -----------------------------------------------------------------------------

PORTAL_DIR="${PORTAL_DIR:-/Users/shenlan/workspaces/ai-workspace-service/portal}"
PAGES_PROJECT="${PAGES_PROJECT_NAME:-ai-workspace-portal-uat}"

echo "==> [Cloudflare Pages UAT] Deploying portal frontend to project: ${PAGES_PROJECT}..."

if [[ -d "${PORTAL_DIR}" ]]; then
  pushd "${PORTAL_DIR}" > /dev/null
  if command -v npx > /dev/null 2>&1 && [[ -d "out" || -d ".next" ]]; then
    npx wrangler pages deploy "${PORTAL_DIR}/out" --project-name="${PAGES_PROJECT}" --branch="uat" || true
  fi
  popd > /dev/null
else
  echo "Warning: Portal directory ${PORTAL_DIR} not found locally, skipping direct Pages upload"
fi

echo "==> [Cloudflare Pages UAT] Portal deployment finished."
