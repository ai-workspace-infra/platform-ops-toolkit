#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloudflare Worker 网关部署脚本
# -----------------------------------------------------------------------------

WORKER_DIR="${WORKER_DIR:?WORKER_DIR must point to a checked-out edge-gateway repository}"

echo "==> [Cloudflare Worker UAT] Deploying edge-gateway..."

test -d "${WORKER_DIR}"
pushd "${WORKER_DIR}" > /dev/null
corepack enable 2>/dev/null || true
npx wrangler deploy --env "${CLOUDFLARE_ENV:-uat}"
popd > /dev/null

echo "==> [Cloudflare Worker UAT] Gateway deployment finished."
