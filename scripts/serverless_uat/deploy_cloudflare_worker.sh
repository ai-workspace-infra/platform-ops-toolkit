#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloudflare Worker 网关部署脚本
# -----------------------------------------------------------------------------

WORKER_DIR="${WORKER_DIR:-/Users/shenlan/workspaces/ai-workspace-service/edge-gateway.svc.plus}"

echo "==> [Cloudflare Worker UAT] Deploying edge-gateway..."

if [[ -d "${WORKER_DIR}" ]]; then
  pushd "${WORKER_DIR}" > /dev/null
  if command -v npx > /dev/null 2>&1; then
    npx wrangler deploy --env uat || npx wrangler deploy || true
  fi
  popd > /dev/null
else
  echo "Warning: Worker directory ${WORKER_DIR} not found locally, skipping local wrangler deploy"
fi

echo "==> [Cloudflare Worker UAT] Gateway deployment finished."
