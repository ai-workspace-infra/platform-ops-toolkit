#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
probe="${root}/.github/scripts/serverless/probe_accounts_schema.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"to_regclass('public.schema_migrations')"*) printf 'absent\n' ;;
  *"information_schema.columns"*) printf '0\n' ;;
  *"to_regclass('public.account_lifecycle_events')"*) printf 'f\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${workdir}/psql"

base=(
  "PATH=${workdir}:${PATH}"
  VAULT_ENV_PATH=uat
  PROJECT_REF=abcdefghijklmnopqrst
  TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:5432/postgres?sslmode=require
)
output="$(env "${base[@]}" bash "${probe}")"
[[ "${output}" == *'migration_version=absent, lifecycle_columns=0/6, lifecycle_events=f'* ]] || {
  echo 'Read-only UAT schema probe did not report the expected metadata.' >&2
  exit 1
}
if env "${base[@]}" VAULT_ENV_PATH=prod bash "${probe}" >/dev/null 2>&1; then
  echo 'Schema probe accepted PROD.' >&2
  exit 1
fi
bad_target_output="$(env "${base[@]}" TARGET_DSN=postgres://postgres.abcdefghijklmnopqrst:placeholder@aws-0-test.pooler.supabase.com:6543/postgres?sslmode=require bash "${probe}" 2>&1)" && {
  echo 'Schema probe accepted a transaction-pooler target.' >&2
  exit 1
}
[[ "${bad_target_output}" == *'port_5432=False'* && "${bad_target_output}" != *'placeholder'* ]] || {
  echo 'Schema probe did not provide safe, redacted diagnostics.' >&2
  exit 1
}
echo 'UAT Accounts schema read-only probe passed.'
