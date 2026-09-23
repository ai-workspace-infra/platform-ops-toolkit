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

valid_baseline=(
  DEPLOY_ENV=uat
  SNAPSHOT_REPOS=
  SNAPSHOT_SOURCE_REF=
  ENABLE_MIGRATION=false
  APPLY_ACCOUNTS_SCHEMA_MIGRATION=false
  ADOPT_ACCOUNTS_BASELINE=true
)
env "${valid_baseline[@]}" bash "${snapshot_validator}"
reject env "${valid_baseline[@]}" ENABLE_MIGRATION=true bash "${snapshot_validator}"
reject env "${valid_baseline[@]}" DEPLOY_ENV=prod bash "${snapshot_validator}"
reject env "${valid_baseline[@]}" SNAPSHOT_REPOS=ai-workspace-services/accounts bash "${snapshot_validator}"
reject env "${valid_baseline[@]}" APPLY_ACCOUNTS_SCHEMA_MIGRATION=true bash "${snapshot_validator}"

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

baseline_serverless=(
  VAULT_ENV_PATH=uat
  OPERATION=deploy
  TARGET_DOMAINS=web-saas
  CLOUD_PROVIDER=vultr-vps
  TAG_REF=uat-daily-build-2026.09.23-r1
  DEPLOY_CLOUD_RUN=true
  DEPLOY_CLOUDFLARE=true
  SERVERLESS_DNS_MODE=none
  ADOPT_ACCOUNTS_BASELINE=true
)
env "${baseline_serverless[@]}" bash "${serverless_validator}" >/dev/null
reject env "${baseline_serverless[@]}" OPERATION=deploy+migrate bash "${serverless_validator}"
reject env "${baseline_serverless[@]}" VAULT_ENV_PATH=prod bash "${serverless_validator}"
reject env "${baseline_serverless[@]}" APPLY_ACCOUNTS_SCHEMA_MIGRATION=true bash "${serverless_validator}"

env VAULT_ENV_PATH=uat OPERATION=plan PROBE_ACCOUNTS_SCHEMA=true \
  bash "${serverless_validator}" >/dev/null
reject env VAULT_ENV_PATH=prod OPERATION=plan PROBE_ACCOUNTS_SCHEMA=true \
  bash "${serverless_validator}"
reject env VAULT_ENV_PATH=uat OPERATION=deploy PROBE_ACCOUNTS_SCHEMA=true \
  TAG_REF=uat-daily-build-2026.09.23-r1 bash "${serverless_validator}"

python3 - "${root}" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
daily = yaml.safe_load((root / '.github/workflows/daily-main-snapshot.yaml').read_text())
serverless = yaml.safe_load((root / '.github/workflows/serverless-orchestrator.yml').read_text())
daily_inputs = daily.get('on', daily.get(True))['workflow_dispatch']['inputs']
if daily_inputs['enable_migration']['default'] is not False:
    raise SystemExit('UAT data migration must be opt-in')
if daily_inputs['adopt_accounts_baseline']['default'] is not False:
    raise SystemExit('UAT baseline adoption must be opt-in')
baseline = serverless['jobs']['uat_accounts_baseline']
cloud_run = serverless['jobs']['cloud_run']
if 'supabase' not in baseline['needs'] or 'uat_accounts_baseline' not in cloud_run['needs']:
    raise SystemExit('UAT baseline must run after Supabase and gate Cloud Run')
if "needs.uat_accounts_baseline.result == 'success'" not in cloud_run['if']:
    raise SystemExit('Cloud Run must stop after a failed UAT baseline upgrade')
sql = (root / '.github/scripts/serverless/uat_accounts_baseline_2026091401.sql').read_text()
for forbidden in ('DROP TABLE', 'TRUNCATE ', 'DELETE FROM ', 'UPDATE PUBLIC.USERS'):
    if forbidden in sql.upper():
        raise SystemExit(f'Expand-only UAT baseline contains {forbidden}')
PY

echo "UAT Accounts schema migration dispatch contract passed."
