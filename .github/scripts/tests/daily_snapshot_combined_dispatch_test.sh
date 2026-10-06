#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export IMPORT_TEST_REPO_ROOT="${repo_root}"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
request_guard="${repo_root}/.github/scripts/snapshots/validate-uat-schema-migration-request.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

grep -Fq 'selfhost_wait_timeout_seconds="${UAT_SELFHOST_WAIT_TIMEOUT_SECONDS:-10800}"' "${dispatcher}"

env DEPLOY_ENV=uat ENABLE_MIGRATION=true DATA_IMPORT_CONFIG_JSON='{}' bash "$request_guard"
if env DEPLOY_ENV=uat ENABLE_MIGRATION=true \
  DATA_IMPORT_CONFIG_JSON='{"dsn":"postgres://synthetic-sensitive.invalid"}' \
  bash "$request_guard" >"$workdir/guard-out" 2>"$workdir/guard-err"; then
  echo 'Sensitive migration config must fail before Vault and builds.' >&2
  exit 1
fi
if grep -Fq 'synthetic-sensitive' "$workdir/guard-out" "$workdir/guard-err"; then
  echo 'Rejected migration credentials must not be echoed.' >&2
  exit 1
fi

cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
printf '%s %s %s\n' "${GH_TOKEN:-none}" "$1" "$2" >> "${GH_LOG}.tokens"
if [[ "$1 $2" == "workflow run" ]]; then
  printf '%s\n' 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/1001'
elif [[ "$1 $2" == "run download" ]]; then
  python3 - "$@" <<'PY'
import json, os, pathlib, re, sys
inputs = json.load(open(os.environ['GH_LOG'] + '.payload'))['inputs']
config = json.loads(inputs['config_json'])
owner = re.search(r'uat-data-import.yaml@([0-9a-f]{40})', pathlib.Path(os.environ['IMPORT_TEST_REPO_ROOT'], '.github/workflows/environment-data-operations.yml').read_text()).group(1)
preview = config.get('dry_run', True)
receipt = dict(schema='uat-data-import/v1', environment=inputs['environment'], correlation_id=inputs['correlation_id'],
               run_id='1002', run_attempt='1', owner_sha=owner, accounts_ref=inputs['accounts_ref'], accounts_sha='a'*40,
               dry_run=preview, target_host=config.get('accounts_target_host',''), caller_run_id=str(config.get('caller_run_id','')),
               success=True, runtime=dict(phase='target_preview' if preview else 'target_verify', category='success',
                                         write_state='not_attempted' if preview else 'verified', convergence_verified=not preview))
scenario = os.environ.get('RECEIPT_SCENARIO','')
if scenario == 'wrong-receipt': receipt['correlation_id'] = 'wrong'
if scenario == 'unverified-import': receipt['runtime']['convergence_verified'] = False
directory = pathlib.Path(sys.argv[sys.argv.index('--dir')+1])
directory.mkdir(exist_ok=True)
if scenario != 'missing-receipt': (directory/'uat-data-import-receipt.json').write_text(json.dumps(receipt))
PY
elif [[ "$1" == api && "$*" == *"/actions/runs/1001"* ]]; then
  printf '%s\n' $'completed\tsuccess'
elif [[ "$1" == api && "$*" == *"--method POST"* ]]; then
  tee "${GH_LOG}.payload" >/dev/null
  printf '{}\n'
elif [[ "$1" == api && "$*" == *"/environment-data-operations.yml/runs?"* ]]; then
  python3 - <<'PY'
import json, os
payload = json.load(open(os.environ['GH_LOG'] + '.payload'))
inputs = payload['inputs']
print(json.dumps({'workflow_runs': [{
    'id': 1002, 'display_title': 'data:' + inputs['correlation_id'] + ' / legacy_import / uat',
    'status': 'completed', 'conclusion': os.environ.get('DATA_CONCLUSION', 'success'),
    'html_url': 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/1002'
}]}))
PY
fi
EOF
chmod +x "${workdir}/gh"

GH_LOG="${workdir}/gh.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
RUN_STATUS_TOKEN=job-token \
SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
SKIP_STRIPE_CATALOG=true \
UAT_SELFHOST_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

grep -Fq 'workflow run hybrid-orchestrator.yml' "${workdir}/gh.log"
# The App token dispatches; the job token (which outlives the 60-minute App
# token) reads the Hybrid run status until it completes.
grep -Fxq 'test-token workflow run' "${workdir}/gh.log.tokens"
grep -Fxq 'job-token api repos/ai-workspace-infra/platform-ops-toolkit/actions/runs/1001' "${workdir}/gh.log.tokens"
if grep -Fq 'test-token api' "${workdir}/gh.log.tokens"; then
  echo 'UAT Hybrid status must not be read with the dispatch App token.' >&2
  exit 1
fi
if grep -Fq 'workflow run open-platform-orchestrator.yml' "${workdir}/gh.log"; then
  echo 'Daily UAT snapshot must not mutate the independent Shared platform lifecycle.' >&2
  exit 1
fi
grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=all' "${workdir}/gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.09.28-r2' "${workdir}/gh.log"
grep -Fq -- '-f source_ref=main' "${workdir}/gh.log"
grep -Fq -- '-f routing_mode=selfhost-first' "${workdir}/gh.log"
if grep -Fq -- 'operation=destroy' "${workdir}/gh.log"; then
  echo 'Daily UAT snapshot must never dispatch destroy.' >&2
  exit 1
fi

# A reviewed schema migration is carried explicitly to Hybrid and then to the
# Serverless child; it must not be rejected or silently dropped before dispatch.
: > "${workdir}/gh.log"
env APPLY_ACCOUNTS_SCHEMA_MIGRATION=true \
  ACCOUNTS_SCHEMA_EXPECTED_VERSION=2026092703 \
  ACCOUNTS_SCHEMA_TARGET_VERSION=2026092801 \
  ACCOUNTS_SCHEMA_SHA256=d066e223641b4eccbb65a00dce70f717b6dce02491d1d54edc1099baf2071433 \
  GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
  SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
  bash "${dispatcher}" >/dev/null
grep -Fq -- '-f apply_accounts_schema_migration=true' "${workdir}/gh.log"
grep -Fq -- '-f accounts_schema_expected_version=2026092703' "${workdir}/gh.log"
grep -Fq -- '-f accounts_schema_target_version=2026092801' "${workdir}/gh.log"
grep -Fq -- '-f accounts_schema_sha256=d066e223641b4eccbb65a00dce70f717b6dce02491d1d54edc1099baf2071433' "${workdir}/gh.log"

# One-time import dispatches the unified data entry and must finish before Hybrid.
: > "${workdir}/gh.log"
env ENABLE_MIGRATION=true DATA_IMPORT_CONFIG_JSON='{"dry_run":false}' \
  GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
  RUN_STATUS_TOKEN=job-token SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
  bash "${dispatcher}" >/dev/null
python3 - "${workdir}/gh.log" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
calls = path.read_text()
assert calls.index('environment-data-operations.yml/dispatches') < calls.index('workflow run hybrid-orchestrator.yml')
payload = json.loads(path.with_suffix('.log.payload').read_text())
assert payload['ref'] == 'main'
inputs = payload['inputs']
assert inputs['environment'] == 'uat' and inputs['mode'] == 'legacy_import'
assert inputs['release_tag'] == inputs['accounts_ref'] == 'uat-daily-build-2026.09.28-r2'
assert json.loads(inputs['config_json']) == {'confirm_legacy_import': True, 'dry_run': False, 'accounts_transport': 'direct'}
tokens = path.with_suffix('.log.tokens').read_text()
assert 'test-token api --method' in tokens
assert 'job-token api repos/' in tokens
PY

# Default preview never deploys applications or authorizes promotion artifacts.
: > "${workdir}/preview.outputs"
: > "${workdir}/gh.log"
env ENABLE_MIGRATION=true GITHUB_OUTPUT="${workdir}/preview.outputs" \
  GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
  SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
  bash "${dispatcher}" >/dev/null
grep -Fq 'environment-data-operations.yml/dispatches' "${workdir}/gh.log"
if grep -Fq 'workflow run hybrid-orchestrator.yml' "${workdir}/gh.log"; then
  echo 'Import preview must not authorize an application deployment.' >&2
  exit 1
fi

if grep -Fq 'promotion_manifest_verified=true' "${workdir}/preview.outputs"; then
  echo 'Import preview must not authorize a promotion artifact upload.' >&2
  exit 1
fi

# Failure/cancellation, unsafe config and mixed schema/import requests stop deployment.
for scenario in failure cancelled bad-config mixed-schema prod bad-boolean wrong-receipt unverified-import missing-receipt; do
  : > "${workdir}/gh.log"
  extra=()
  case "$scenario" in
    failure|cancelled) extra+=("DATA_CONCLUSION=$scenario");;
    bad-config) extra+=('DATA_IMPORT_CONFIG_JSON={"dry_run":false,"dsn":"postgres://sensitive.invalid"}');;
    mixed-schema) extra+=(APPLY_ACCOUNTS_SCHEMA_MIGRATION=true);;
    prod) extra+=(DEPLOY_ENV=prod);;
    bad-boolean) extra+=(ENABLE_MIGRATION=invalid);;
    wrong-receipt|unverified-import|missing-receipt) extra+=("RECEIPT_SCENARIO=$scenario");;
  esac
  if env ENABLE_MIGRATION=true DATA_IMPORT_CONFIG_JSON='{"dry_run":false}' "${extra[@]}" \
    GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
    SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
    bash "${dispatcher}" >"${workdir}/out" 2>"${workdir}/err"; then
    echo "Unsafe import scenario $scenario must fail." >&2
    exit 1
  fi
  if grep -Fq 'workflow run hybrid-orchestrator.yml' "${workdir}/gh.log"; then
    echo "Unsafe import scenario $scenario must not deploy." >&2
    exit 1
  fi
done

# Unimplemented release overrides still fail before any dispatch.
for unsupported in XCONNECT_ONE_RELEASE_TAG=v1.2.3 \
    XCONNECT_GATEWAY_RELEASE_TAG=v1.2.3; do
  : > "${workdir}/gh.log"
  if env "${unsupported}" \
    GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
    SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
    bash "${dispatcher}" >/dev/null 2>"${workdir}/err"; then
    echo "UAT dispatch must reject ${unsupported} (Hybrid cannot carry it)." >&2
    exit 1
  fi
  grep -Fiq "${unsupported%%=*}" "${workdir}/err"
  if [[ -s "${workdir}/gh.log" ]]; then
    echo "Rejected request ${unsupported} must not dispatch anything." >&2
    exit 1
  fi
done

echo "daily_snapshot_combined_dispatch_test: PASS"
