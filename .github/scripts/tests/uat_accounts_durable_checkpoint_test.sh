#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
checkpoint_script="${root}/.github/scripts/database/create_release_checkpoint.sh"
workflow="${root}/.github/workflows/serverless-orchestrator.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'touch "${PSQL_CALLED}"' >"${tmp}/bin/psql"
chmod +x "${tmp}/bin/psql"

if output="$(env PATH="${tmp}/bin:${PATH}" PSQL_CALLED="${tmp}/psql-called" \
  RELEASE_TAG=uat-daily-build-2026.09.23-r1 DATABASE_BACKEND=supabase DATABASE_ENV=uat \
  TARGET_DSN=postgres://user:secret@db.supabase.com/postgres REQUIRE_DURABLE_CHECKPOINT=true \
  bash "${checkpoint_script}" 2>&1)"; then
  echo 'Durable UAT checkpoint accepted missing remote backup credentials.' >&2
  exit 1
fi
[[ ! -e "${tmp}/psql-called" ]] || { echo 'Checkpoint attempted SQL before the remote backup preflight.' >&2; exit 1; }
[[ "${output}" == *'requires configured remote object storage credentials'* ]] || {
  echo 'Checkpoint did not explain the fail-closed storage preflight.' >&2
  exit 1
}
[[ "${output}" != *'secret'* && "${output}" != *'postgres://'* ]] || {
  echo 'Checkpoint preflight exposed the DSN.' >&2
  exit 1
}

mkdir -p "${tmp}/success-bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *"server_version_num"*) printf "15\\n" ;;' \
  '  *"CREATE TABLE IF NOT EXISTS public.system_release_checkpoints"*) ;;' \
  '  *"INSERT INTO public.system_release_checkpoints"*) touch "${LEDGER_RECORDED}" ;;' \
  '  *) exit 4 ;;' \
  'esac' >"${tmp}/success-bin/psql"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$1" == "--version" ]]; then printf "pg_dump (PostgreSQL) 15.0\\n"; exit 0; fi' \
  'for arg in "$@"; do [[ "$arg" == --file=* ]] && dump_file="${arg#--file=}"; done' \
  '[[ -n "${dump_file:-}" ]] || exit 5' \
  'printf "%s\\n" "-- private fixture row" >"${dump_file}"' >"${tmp}/success-bin/pg_dump"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$1 $2" == "s3 cp" ]]; then' \
  '  [[ "$3" == *.enc && -s "$3" ]] || exit 6' \
  '  touch "${REMOTE_OBJECT_UPLOADED}"' \
  '  exit 0' \
  'fi' \
  'if [[ "$1 $2" == "s3api head-object" ]]; then' \
  '  [[ -e "${REMOTE_OBJECT_UPLOADED}" ]] || exit 7' \
  '  printf "17\\n"' \
  '  exit 0' \
  'fi' \
  'exit 8' >"${tmp}/success-bin/aws"
chmod +x "${tmp}/success-bin/psql" "${tmp}/success-bin/pg_dump" "${tmp}/success-bin/aws"
success_output="${tmp}/success-output"
if output="$(env PATH="${tmp}/success-bin:${PATH}" RELEASE_TAG=uat-daily-build-2026.09.23-r1 \
  DATABASE_BACKEND=supabase DATABASE_ENV=uat GIT_SHA=0123456789012345678901234567890123456789 \
  TARGET_DSN=postgres://user:secret@db.supabase.com/postgres S3_BUCKET=uat-checkpoints \
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test BACKUP_ENCRYPTION_PASS=test-encryption \
  REQUIRE_DURABLE_CHECKPOINT=true CHECKPOINT_DIR="${tmp}/checkpoint" RUNNER_TEMP="${tmp}" \
  GITHUB_OUTPUT="${success_output}" LEDGER_RECORDED="${tmp}/ledger-recorded" \
  REMOTE_OBJECT_UPLOADED="${tmp}/remote-object-uploaded" bash "${checkpoint_script}" 2>&1)"; then
  :
else
  echo "A valid encrypted remote checkpoint was rejected: ${output}" >&2
  exit 1
fi
[[ -e "${tmp}/ledger-recorded" && -e "${tmp}/remote-object-uploaded" ]] || {
  echo 'Successful checkpoint did not verify both remote object and ledger evidence.' >&2
  exit 1
}
[[ "$(<"${success_output}")" == 'durable_checkpoint_verified=true' ]] || {
  echo 'Successful checkpoint did not emit its non-sensitive verification result.' >&2
  exit 1
}
python3 - "${tmp}/checkpoint/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
if manifest['environment'] != 'uat' or not manifest['s3_uri'].endswith('.sql.gz.enc'):
    raise SystemExit('Checkpoint manifest did not bind UAT to an encrypted remote object.')
PY
[[ "${output}" != *'secret'* && "${output}" != *'postgres://'* && "${output}" != *'private fixture row'* ]] || {
  echo 'Checkpoint logs exposed a DSN or private row fixture.' >&2
  exit 1
}

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text())
jobs = workflow['jobs']
supabase = jobs['supabase']
migration = jobs['uat_accounts_schema_migration']
cloud_run = jobs['cloud_run']
artifact = next(step for step in supabase['steps'] if step.get('uses', '').startswith('actions/upload-artifact'))
if 'manifest.json' not in artifact['with']['path']:
    raise SystemExit('Checkpoint artifact must contain only the non-sensitive manifest.')
if '.sql' in artifact['with']['path'] or '.gz' in artifact['with']['path']:
    raise SystemExit('Sensitive SQL checkpoint content must never be uploaded as a workflow artifact.')
if supabase.get('outputs', {}).get('durable_checkpoint_verified') != '${{ steps.checkpoint.outputs.durable_checkpoint_verified }}':
    raise SystemExit('Supabase job must expose only the verified checkpoint boolean to migration.')
if next(step for step in supabase['steps'] if step.get('id') == 'checkpoint')['env'].get('REQUIRE_DURABLE_CHECKPOINT') != '${{ inputs.apply_accounts_schema_migration || false }}':
    raise SystemExit('Migration requests must activate durable checkpoint preflight.')
if 'durable_checkpoint_verified' not in str(next(step for step in migration['steps'] if step.get('name', '').startswith('Apply reviewed'))['env'].get('RELEASE_CHECKPOINT_VERIFIED')):
    raise SystemExit('Migration must consume the verified checkpoint result.')
if 'uat_accounts_schema_migration' not in cloud_run['needs']:
    raise SystemExit('Cloud Run must depend on the migration gate.')
for job_name in ('cloudflare_ssr', 'frontend_router', 'edge_gateway'):
    if 'backend_gate' not in jobs[job_name]['needs']:
        raise SystemExit(f'{job_name} must remain behind the backend migration/deployment gate.')
PY

echo 'UAT Accounts durable checkpoint gate passed.'
