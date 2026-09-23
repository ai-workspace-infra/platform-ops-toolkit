#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
snapshot_validator="${root}/.github/scripts/snapshots/validate-uat-schema-migration-request.sh"
serverless_validator="${root}/.github/scripts/serverless/validate_dispatch_inputs.sh"
sha="$(printf 'a%.0s' {1..64})"

env APPLY_ACCOUNTS_SCHEMA_MIGRATION=false bash "${snapshot_validator}"

valid_snapshot=(
  DEPLOY_ENV=uat
  SNAPSHOT_REPOS=
  SNAPSHOT_SOURCE_REF=
  APPLY_ACCOUNTS_SCHEMA_MIGRATION=true
  ENABLE_MIGRATION=false
  ACCOUNTS_SCHEMA_EXPECTED_VERSION=2026091401
  ACCOUNTS_SCHEMA_TARGET_VERSION=2026092301
  "ACCOUNTS_SCHEMA_SHA256=${sha}"
)
env "${valid_snapshot[@]}" bash "${snapshot_validator}"

reject() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected request rejection: $*" >&2
    exit 1
  fi
}

reject env "${valid_snapshot[@]}" ENABLE_MIGRATION=true bash "${snapshot_validator}"
reject env "${valid_snapshot[@]}" DEPLOY_ENV=prod bash "${snapshot_validator}"
reject env "${valid_snapshot[@]}" SNAPSHOT_REPOS=ai-workspace-services/accounts bash "${snapshot_validator}"
reject env "${valid_snapshot[@]}" SNAPSHOT_SOURCE_REF=main bash "${snapshot_validator}"
reject env "${valid_snapshot[@]}" ACCOUNTS_SCHEMA_SHA256=bad bash "${snapshot_validator}"
reject env APPLY_ACCOUNTS_SCHEMA_MIGRATION=false ACCOUNTS_SCHEMA_TARGET_VERSION=2026092301 bash "${snapshot_validator}"

valid_serverless=(
  VAULT_ENV_PATH=uat
  OPERATION=deploy
  TARGET_DOMAINS=web-saas
  CLOUD_PROVIDER=vultr-vps
  TAG_REF=uat-daily-build-2026.09.23-r1
  DEPLOY_CLOUD_RUN=true
  DEPLOY_CLOUDFLARE=true
  SERVERLESS_DNS_MODE=none
  APPLY_ACCOUNTS_SCHEMA_MIGRATION=true
  ACCOUNTS_SCHEMA_EXPECTED_VERSION=2026091401
  ACCOUNTS_SCHEMA_TARGET_VERSION=2026092301
  "ACCOUNTS_SCHEMA_SHA256=${sha}"
)
env "${valid_serverless[@]}" bash "${serverless_validator}" >/dev/null
reject env "${valid_serverless[@]}" VAULT_ENV_PATH=prod bash "${serverless_validator}"
reject env "${valid_serverless[@]}" OPERATION=deploy+migrate bash "${serverless_validator}"
reject env "${valid_serverless[@]}" DEPLOY_CLOUD_RUN=false bash "${serverless_validator}"

echo "UAT Accounts schema migration dispatch contract passed."
