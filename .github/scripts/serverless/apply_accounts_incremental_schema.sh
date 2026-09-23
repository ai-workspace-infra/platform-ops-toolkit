#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 2; }

[[ "${VAULT_ENV_PATH:-}" == "uat" ]] || fail "Accounts incremental schema migration is UAT-only."
snapshot_tag="${SNAPSHOT_TAG:-}"
[[ "${snapshot_tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[1-9][0-9]*$ ]] || fail "An immutable UAT snapshot tag is required."

accounts_dir="${ACCOUNTS_DIR:-}"
[[ -d "${accounts_dir}/sql/migrations" && -f "${accounts_dir}/go.mod" ]] || fail "Accounts migration source is missing."
target_dsn="${TARGET_DSN:-}"
project_ref="${PROJECT_REF:-}"
[[ "${project_ref}" =~ ^[a-z0-9]{20}$ ]] || fail "Vault PROJECT_REF is missing or invalid."
command -v python3 >/dev/null || fail "Python 3 is required to validate the target connection."
if ! target_dsn="$(TARGET_DSN="${target_dsn}" PROJECT_REF="${project_ref}" python3 "$(dirname "${BASH_SOURCE[0]}")/normalize_accounts_uat_dsn.py")"; then
  fail "Target connection does not match the UAT Supabase session pooler project."
fi

expected="${ACCOUNTS_SCHEMA_EXPECTED_VERSION:-}"
target="${ACCOUNTS_SCHEMA_TARGET_VERSION:-}"
expected_sha="${ACCOUNTS_SCHEMA_SHA256:-}"
[[ "${expected}" =~ ^[0-9]+$ && "${target}" =~ ^[0-9]+$ && "${target}" -gt "${expected}" ]] || fail "Expected and target versions must be increasing numbers."
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || fail "A lowercase SHA-256 digest is required."
command -v psql >/dev/null || fail "psql is required."
command -v go >/dev/null || fail "Go is required to run Accounts migratectl."

shopt -s nullglob
migration_files=("${accounts_dir}/sql/migrations/${target}_"*.up.sql)
[[ ${#migration_files[@]} -eq 1 ]] || fail "Exactly one target .up.sql migration must exist in the snapshot."
migration_file="${migration_files[0]}"
if command -v sha256sum >/dev/null; then
  actual_sha="$(sha256sum "${migration_file}" | awk '{print $1}')"
elif command -v shasum >/dev/null; then
  actual_sha="$(shasum -a 256 "${migration_file}" | awk '{print $1}')"
else
  fail "A SHA-256 utility is required."
fi
[[ "${actual_sha}" == "${expected_sha}" ]] || fail "Target migration checksum differs from the reviewed digest."

if grep -Eiq '^[[:space:]]*(DROP|TRUNCATE|DELETE|UPDATE)[[:space:]]' "${migration_file}"; then
  fail "The selected migration contains a top-level destructive or data-rewriting statement."
fi

pending=0
for file in "${accounts_dir}"/sql/migrations/*.up.sql; do
  name="${file##*/}"
  version="${name%%_*}"
  [[ "${version}" =~ ^[0-9]+$ ]] || fail "Invalid migration filename in the selected Accounts tag."
  if (( 10#${version} > 10#${expected} )); then
    ((pending += 1))
    [[ "${version}" == "${target}" ]] || fail "The selected tag contains another pending migration; deploy separately."
  fi
done
[[ ${pending} -eq 1 ]] || fail "The selected tag must contain exactly one pending migration."

current="$(psql "${target_dsn}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT version::text || ':' || dirty::text FROM public.schema_migrations LIMIT 1" 2>/dev/null)" || fail "Could not read UAT schema_migrations."
[[ "${current}" == "${expected}:false" ]] || fail "UAT schema version/dirty state differs from the reviewed precondition."

echo "Applying Accounts migration ${target} from ${snapshot_tag} (sha256 ${actual_sha}) to UAT."
(cd "${accounts_dir}" && go run ./cmd/migratectl migrate --dsn "${target_dsn}" --dir sql/migrations)

after="$(psql "${target_dsn}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT version::text || ':' || dirty::text FROM public.schema_migrations LIMIT 1" 2>/dev/null)" || fail "Could not verify UAT schema_migrations after apply."
[[ "${after}" == "${target}:false" ]] || fail "UAT schema did not reach the expected clean target version."
echo "Verified Accounts UAT schema migration ${expected} -> ${target}."
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Accounts UAT schema migration: `%s` → `%s`, snapshot `%s`, SHA-256 `%s`.\n' "${expected}" "${target}" "${snapshot_tag}" "${actual_sha}" >>"${GITHUB_STEP_SUMMARY}"
fi
