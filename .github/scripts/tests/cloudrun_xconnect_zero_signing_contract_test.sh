#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
orchestrator="${repo_root}/scripts/serverless_uat/deploy_orchestrator.py"
deploy_script="${repo_root}/scripts/serverless_uat/deploy_cloudrun_services.sh"

grep -Fq 'f"kv/data/{VAULT_ENV_PATH}/xconnect-one"' "${orchestrator}" || {
  echo "Accounts deployment must read the environment-scoped XConnect Zero secret" >&2
  exit 1
}

grep -Fq 'optional_runtime_secrets(' "${orchestrator}" || {
  echo "Accounts deployment must treat XConnect Zero Signing as optional" >&2
  exit 1
}

for field in ZERO_SIGNING_PRIVATE_KEY ZERO_SIGNING_KEY_ID; do
  grep -Fq "\"${field}\"" "${orchestrator}" || {
    echo "Accounts deployment must recognize optional ${field}" >&2
    exit 1
  }
done

for variable in XCONNECT_OVERLAY_SIGNING_PRIVATE_KEY XCONNECT_OVERLAY_SIGNING_KEY_ID; do
  grep -Fq "${variable}=\${${variable}}" "${deploy_script}" || {
    echo "Cloud Run accounts must forward optional ${variable} when configured" >&2
    exit 1
  }
done

grep -Fq 'XConnect Zero Signing configuration must include both' "${deploy_script}" || {
  echo "Cloud Run accounts must reject partial XConnect Zero Signing configuration" >&2
  exit 1
}

# The UAT shared-node contract is explicit and deployment-scoped: Accounts
# signs a Gateway config for the private Xray Unix socket behind shared Caddy,
# while PROD keeps the direct-TLS default until it opts in independently.
grep -Fq 'if [[ "${DEPLOY_ENV}" == "uat" ]]; then' "${deploy_script}" || {
  echo "Cloud Run accounts must scope shared Caddy Gateway frontend to UAT" >&2
  exit 1
}
grep -Fq 'XCONNECT_GATEWAY_XRAY_FRONTEND=${XCONNECT_GATEWAY_XRAY_FRONTEND:-caddy-unix-h2c}' "${deploy_script}" || {
  echo "UAT Accounts must receive the caddy-unix-h2c Gateway frontend contract" >&2
  exit 1
}
grep -Fq 'XCONNECT_GATEWAY_XRAY_LISTEN_SOCKET=${XCONNECT_GATEWAY_XRAY_LISTEN_SOCKET:-/run/xconnect-gateway/xray.sock}' "${deploy_script}" || {
  echo "UAT Accounts must receive the Gateway Unix socket contract" >&2
  exit 1
}

echo "cloudrun_xconnect_zero_signing_contract_test: PASS"
