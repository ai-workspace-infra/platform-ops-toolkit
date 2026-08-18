#!/usr/bin/env bash
set -euo pipefail

FRONTEND_ROUTER_DIR="${FRONTEND_ROUTER_DIR:?FRONTEND_ROUTER_DIR must point to a checked-out frontend-router repository}"
CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps routing manifest}"

test -d "${FRONTEND_ROUTER_DIR}"
test -f "${CONFIG_FILE}"
test -x "${FRONTEND_ROUTER_DIR}/scripts/deploy_from_gitops.sh"

pushd "${FRONTEND_ROUTER_DIR}" >/dev/null
npm ci
FRONTEND_ROUTER_CONFIG_FILE="${CONFIG_FILE}" bash scripts/deploy_from_gitops.sh
popd >/dev/null
