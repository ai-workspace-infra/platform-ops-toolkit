#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT_SCRIPT="${REPO_ROOT}/scripts/serverless_uat/init_supabase_account_db.sh"
ORCHESTRATOR="${REPO_ROOT}/scripts/serverless_uat/deploy_orchestrator.py"

if [[ "${INITIALIZE_SUPABASE:-false}" == "true" ]]; then
  bash "${INIT_SCRIPT}" \
    --env "${VAULT_ENV_PATH}" \
    --schema-file "${ACCOUNT_SCHEMA_FILE}" \
    --write-account-password
fi

if [[ "${VERIFY_SUPABASE:-false}" == "true" ]]; then
  DEPLOY_CLOUDFLARE=false \
  DEPLOY_CLOUD_RUN=false \
  VERIFY_SUPABASE=true \
  python3 "${ORCHESTRATOR}"
fi
