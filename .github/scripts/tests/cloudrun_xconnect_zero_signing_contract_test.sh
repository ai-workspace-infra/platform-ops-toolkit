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

echo "cloudrun_xconnect_zero_signing_contract_test: PASS"
