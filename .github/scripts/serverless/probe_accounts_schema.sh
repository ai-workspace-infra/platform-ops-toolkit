#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 2; }
[[ "${VAULT_ENV_PATH:-}" == "uat" ]] || fail "Accounts schema probe is UAT-only."
[[ "${PROJECT_REF:-}" =~ ^[a-z0-9]{20}$ ]] || fail "Vault PROJECT_REF is missing or invalid."
command -v psql >/dev/null || fail "psql is required."
command -v python3 >/dev/null || fail "Python 3 is required."

if ! dsn="$(python3 "$(dirname "${BASH_SOURCE[0]}")/normalize_accounts_uat_dsn.py")"; then
  fail "Target connection does not match the UAT Supabase session pooler project."
fi
table="$(psql "${dsn}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT COALESCE(to_regclass('public.schema_migrations')::text, 'absent')" 2>/dev/null)" || fail "UAT database schema probe failed."
version="absent"
if [[ "${table}" != "absent" ]]; then
  version="$(psql "${dsn}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT version::text || ':' || dirty::text FROM public.schema_migrations LIMIT 1" 2>/dev/null)" || fail "Could not inspect schema_migrations."
  [[ -n "${version}" ]] || version="empty"
fi
columns="$(psql "${dsn}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name IN ('account_lifecycle_state','account_lifecycle_changed_at','account_lifecycle_actor_type','account_lifecycle_actor_ref','account_lifecycle_reason','account_lifecycle_transition_id')" 2>/dev/null)" || fail "Could not inspect lifecycle columns."
events="$(psql "${dsn}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('public.account_lifecycle_events') IS NOT NULL" 2>/dev/null)" || fail "Could not inspect lifecycle event table."
echo "UAT Accounts schema: migration_version=${version}, lifecycle_columns=${columns}/6, lifecycle_events=${events}."
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Accounts UAT schema probe (read-only): version `%s`, lifecycle columns `%s/6`, event table `%s`.\n' "${version}" "${columns}" "${events}" >>"${GITHUB_STEP_SUMMARY}"
fi
