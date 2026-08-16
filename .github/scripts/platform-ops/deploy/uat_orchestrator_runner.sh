#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GitHub Actions UAT Orchestration Runner
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/serverless_uat" && pwd)"

echo "==> [CI Runner] Running UAT Serverless Orchestration..."

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
export VAULT_ENV_PATH="${VAULT_ENV_PATH:-${DEPLOY_ENV:-uat}}"
export VAULT_SERVERLESS_PATH="${VAULT_SERVERLESS_PATH:-kv/data/${VAULT_ENV_PATH}/serverless}"

python3 "${SCRIPT_DIR}/deploy_orchestrator.py"

echo "==> [CI Runner] UAT Serverless Orchestration completed."
