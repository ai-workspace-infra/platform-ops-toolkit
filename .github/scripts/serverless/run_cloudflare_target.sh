#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/scripts/serverless_uat"

case "${CLOUDFLARE_TARGET:-}" in
  ssr|edge-worker|page-worker)
    bash "${SCRIPT_DIR}/deploy_portal_opennext_worker.sh"
    ;;
  static-pages|dashboard|pages)
    bash "${SCRIPT_DIR}/deploy_cloudflare_pages.sh"
    ;;
  frontend-router)
    bash "${SCRIPT_DIR}/deploy_frontend_router.sh"
    ;;
  edge-gateway)
    : "${EDGE_GATEWAY_BOUNDARY:?EDGE_GATEWAY_BOUNDARY must be auth, admin, or core}"
    bash "${SCRIPT_DIR}/deploy_cloudflare_worker.sh"
    ;;
  *)
    echo "Unsupported Cloudflare target: ${CLOUDFLARE_TARGET:-<empty>}" >&2
    exit 2
    ;;
esac
