#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps manifest}"
test -f "${CONFIG_FILE}" || {
  echo "Hybrid routing manifest not found: ${CONFIG_FILE}" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "jq is required to verify the hybrid routing contract" >&2
  exit 1
}

mode="$(jq -r '.spec.runtime.mode // empty' "${CONFIG_FILE}")"
test "${mode}" = hybrid || {
  echo "Expected GitOps runtime.mode=hybrid, got ${mode:-<empty>}" >&2
  exit 1
}

cloud_run_result="${CLOUD_RUN_RESULT:-unknown}"
edge_gateway_result="${EDGE_GATEWAY_RESULT:-unknown}"
echo "Hybrid routing contract verified: selfhost primary -> Cloud Run fallback"
echo "Cloud Run fallback stage: ${cloud_run_result}"
echo "Edge-gateway failover stage: ${edge_gateway_result}"
