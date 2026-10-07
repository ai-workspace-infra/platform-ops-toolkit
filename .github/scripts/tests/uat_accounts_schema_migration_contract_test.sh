#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
serverless_validator="${root}/.github/scripts/serverless/validate_dispatch_inputs.sh"
sha="$(printf 'a%.0s' {1..64})"

reject() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected request rejection: $*" >&2
    exit 1
  fi
}

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

repair=("${valid_serverless[@]}" OPERATION=repair-schema DEPLOY_CLOUD_RUN=false DEPLOY_CLOUDFLARE=false
  TAG_REF=daily-build-2026.10.04-r3 ACCOUNTS_SCHEMA_EXPECTED_VERSION=2026092703
  ACCOUNTS_SCHEMA_TARGET_VERSION=2026092801
  ACCOUNTS_SCHEMA_SHA256=d066e223641b4eccbb65a00dce70f717b6dce02491d1d54edc1099baf2071433)
env "${repair[@]}" bash "${serverless_validator}" >/dev/null
reject env "${repair[@]}" VAULT_ENV_PATH=prod bash "${serverless_validator}"
reject env "${repair[@]}" DEPLOY_CLOUD_RUN=true bash "${serverless_validator}"
reject env "${repair[@]}" DEPLOY_CLOUDFLARE=true bash "${serverless_validator}"
reject env "${repair[@]}" SERVERLESS_DNS_MODE=uat-records bash "${serverless_validator}"
reject env "${repair[@]}" TAG_REF=main bash "${serverless_validator}"
reject env "${repair[@]}" APPLY_ACCOUNTS_SCHEMA_MIGRATION=false bash "${serverless_validator}"

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
serverless = yaml.safe_load((root / '.github/workflows/serverless-orchestrator.yml').read_text())
baseline = serverless['jobs']['uat_accounts_baseline']
cloud_run = serverless['jobs']['cloud_run']
if 'supabase' not in baseline['needs'] or 'uat_accounts_baseline' not in cloud_run['needs']:
    raise SystemExit('UAT baseline must run after Supabase and gate Cloud Run')
if "needs.uat_accounts_baseline.result == 'success'" not in cloud_run['if']:
    raise SystemExit('Cloud Run must stop after a failed UAT baseline upgrade')
for job_name, mode in (('uat_accounts_baseline', 'baseline'), ('uat_accounts_schema_migration', 'migrate')):
    steps = serverless['jobs'][job_name]['steps']
    calls = [step for step in steps if 'environment-upgrade/dispatch.py' in step.get('run', '')]
    if len(calls) != 1 or calls[0]['env']['DATA_OPERATION'] != mode:
        raise SystemExit('Requested schema steps must dispatch one owned, reviewed executor')
# SQL and implementation-level repair assertions now run in Playbooks owner CI.
PY

echo "UAT Accounts schema migration dispatch contract passed."
