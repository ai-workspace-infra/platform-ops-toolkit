#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
apply_script="${root}/.github/scripts/serverless/apply_accounts_incremental_schema.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/bin" "${workdir}/accounts/sql/migrations"
printf 'module account\n\ngo 1.23\n' >"${workdir}/accounts/go.mod"
printf '%s\n' '-- reviewed additive test migration' 'ALTER TABLE public.users ADD COLUMN IF NOT EXISTS test_marker TEXT;' \
  >"${workdir}/accounts/sql/migrations/2026092301_test_marker.up.sql"

printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "$*" == *"sslmode=require"* ]] || exit 3' \
  'case "$*" in' \
  '  *"information_schema.columns"*) printf "%s\\n" "${TEST_SCHEMA_PROBE:-4:1:4}" ;;' \
  '  *"string_agg"*) if [[ -e "${TEST_APPLIED_MARKER}" ]]; then printf "%s\\n" "${TEST_USER_SENTINEL:-2:0123456789abcdef0123456789abcdef}"; else printf "2:0123456789abcdef0123456789abcdef\\n"; fi ;;' \
  '  *) if [[ -e "${TEST_APPLIED_MARKER}" ]]; then printf "2026092301:false\\n"; else printf "2026091401:false\\n"; fi ;;' \
  'esac' \
  >"${workdir}/bin/psql"
printf '%s\n' '#!/usr/bin/env bash' '[[ "$*" == *"sslmode=require"* ]] || exit 3' 'touch "${TEST_APPLIED_MARKER}"' >"${workdir}/bin/go"
chmod +x "${workdir}/bin/psql" "${workdir}/bin/go"

if command -v sha256sum >/dev/null; then
  checksum="$(sha256sum "${workdir}/accounts/sql/migrations/2026092301_test_marker.up.sql" | awk '{print $1}')"
else
  checksum="$(shasum -a 256 "${workdir}/accounts/sql/migrations/2026092301_test_marker.up.sql" | awk '{print $1}')"
fi

common=(
  "PATH=${workdir}/bin:${PATH}"
  VAULT_ENV_PATH=uat
  SNAPSHOT_TAG=uat-daily-build-2026.09.23-r1
  "ACCOUNTS_DIR=${workdir}/accounts"
  TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:5432/postgres?sslmode=require
  PROJECT_REF=abcdefghijklmnopqrst
  ACCOUNTS_SCHEMA_EXPECTED_VERSION=2026091401
  ACCOUNTS_SCHEMA_TARGET_VERSION=2026092301
  "ACCOUNTS_SCHEMA_SHA256=${checksum}"
  RELEASE_CHECKPOINT_VERIFIED=true
  "TEST_APPLIED_MARKER=${workdir}/applied"
)

env "${common[@]}" bash "${apply_script}" >/dev/null
[[ -e "${workdir}/applied" ]] || { echo 'Expected migratectl invocation.' >&2; exit 1; }
rm -f "${workdir}/applied"
env "${common[@]}" TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:5432/postgres bash "${apply_script}" >/dev/null
[[ -e "${workdir}/applied" ]] || { echo 'Expected migration with normalized TLS connection.' >&2; exit 1; }

reject_without_apply() {
  rm -f "${workdir}/applied"
  if "$@" >/dev/null 2>&1; then
    echo "Expected schema migration preflight to reject: $*" >&2
    exit 1
  fi
  [[ ! -e "${workdir}/applied" ]] || { echo 'Migration ran despite a failed preflight.' >&2; exit 1; }
}

reject_without_apply env "${common[@]}" VAULT_ENV_PATH=prod bash "${apply_script}"
reject_without_apply env "${common[@]}" RELEASE_CHECKPOINT_VERIFIED=false bash "${apply_script}"
reject_without_apply env "${common[@]}" ACCOUNTS_SCHEMA_SHA256="$(printf 'a%.0s' {1..64})" bash "${apply_script}"
reject_without_apply env "${common[@]}" TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:6543/postgres bash "${apply_script}"
reject_without_apply env "${common[@]}" TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:5432/postgres?sslmode=disable bash "${apply_script}"
printf '%s\n' '-- another pending migration' >"${workdir}/accounts/sql/migrations/2026092401_other.up.sql"
reject_without_apply env "${common[@]}" bash "${apply_script}"
rm -f "${workdir}/accounts/sql/migrations/2026092401_other.up.sql"

reject_without_apply env "${common[@]}" TEST_SCHEMA_PROBE=4:0:4 bash "${apply_script}"
rm -f "${workdir}/applied"
if env "${common[@]}" TEST_USER_SENTINEL=3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash "${apply_script}" >/dev/null 2>&1; then
  echo 'Migration did not fail when the post-migration user/subscription sentinel changed.' >&2
  exit 1
fi
[[ -e "${workdir}/applied" ]] || { echo 'Expected the post-migration sentinel check to run after migration.' >&2; exit 1; }
rm -f "${workdir}/applied"

if output="$(env "${common[@]}" bash "${apply_script}" 2>&1)"; then
  :
else
  echo "Expected a clean migration test run: ${output}" >&2
  exit 1
fi
[[ "${output}" != *"placeholder"* && "${output}" != *"postgres://"* ]] || {
  echo 'Migration logs exposed a DSN value.' >&2
  exit 1
}

echo 'UAT Accounts schema apply guard passed.'
