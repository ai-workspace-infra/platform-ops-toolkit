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

printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == *"sslmode=require"* ]] || exit 3' 'if [[ -e "${TEST_APPLIED_MARKER}" ]]; then printf "2026092301:false\\n"; else printf "2026091401:false\\n"; fi' \
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
reject_without_apply env "${common[@]}" ACCOUNTS_SCHEMA_SHA256="$(printf 'a%.0s' {1..64})" bash "${apply_script}"
reject_without_apply env "${common[@]}" TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:6543/postgres bash "${apply_script}"
reject_without_apply env "${common[@]}" TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:5432/postgres?sslmode=disable bash "${apply_script}"
printf '%s\n' '-- another pending migration' >"${workdir}/accounts/sql/migrations/2026092401_other.up.sql"
reject_without_apply env "${common[@]}" bash "${apply_script}"

echo 'UAT Accounts schema apply guard passed.'
