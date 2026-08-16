#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloudflare Worker 网关部署脚本
# -----------------------------------------------------------------------------

WORKER_DIR="${WORKER_DIR:?WORKER_DIR must point to a checked-out edge-gateway repository}"

case "${EDGE_GATEWAY_BOUNDARY:-}" in
  auth) WORKER_CONFIG="wrangler.auth.toml" ;;
  admin) WORKER_CONFIG="wrangler.admin.toml" ;;
  core) WORKER_CONFIG="wrangler.core.toml" ;;
  *)
    echo "EDGE_GATEWAY_BOUNDARY must be auth, admin, or core" >&2
    exit 2
    ;;
esac

echo "==> [Cloudflare Worker UAT] Deploying edge-gateway boundary: ${EDGE_GATEWAY_BOUNDARY}..."

test -d "${WORKER_DIR}"
pushd "${WORKER_DIR}" > /dev/null
corepack enable 2>/dev/null || true
npx wrangler deploy --config "${WORKER_CONFIG}" --env "${CLOUDFLARE_ENV:-uat}"
popd > /dev/null

echo "==> [Cloudflare Worker UAT] Edge-gateway ${EDGE_GATEWAY_BOUNDARY} deployment finished."
