#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly CONFIRMATION='RESET-UAT-XCONNECT-OVERLAY'
readonly DEFAULT_VAULT_PATH='kv/uat/serverless/supabase'
readonly OVERLAY_TABLES=(
  overlay_signed_config_acks
  overlay_enrollment_sessions
  overlay_device_credentials
  overlay_registrations
  overlay_devices
  overlay_invites
  overlay_networks
)
readonly TRANSITIONAL_TABLES=(overlay_config_acks overlay_nodes)

drop_transitional=0
confirmed=0
check_only=0
if [[ "${1:-}" == '--check-only' && "$#" -eq 1 ]]; then
  check_only=1
  shift
fi
if [[ "${1:-}" == '--confirm' && "${2:-}" == "$CONFIRMATION" ]]; then
  confirmed=1
  shift 2
  if [[ "${1:-}" == '--drop-transitional' ]]; then
    drop_transitional=1
    shift
  fi
fi
if (( ! confirmed && ! check_only )) || [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 --check-only | --confirm $CONFIRMATION [--drop-transitional]" >&2
  exit 2
fi

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_SUPABASE_PATH="${VAULT_SUPABASE_PATH:-$DEFAULT_VAULT_PATH}"
if [[ -z "${VAULT_TOKEN:-}" && -n "${VAULT_TOKEN_FILE:-}" && -s "$VAULT_TOKEN_FILE" ]]; then
  export VAULT_TOKEN="$(<"$VAULT_TOKEN_FILE")"
fi
command -v vault >/dev/null || { echo 'vault CLI is required' >&2; exit 1; }
command -v psql >/dev/null || { echo 'psql is required' >&2; exit 1; }

# Never pass the URI to psql: libpq would expose the password in the process
# arguments. Parse it once from stdin and use libpq environment variables.
# The session pooler is used because the Supabase direct endpoint may prefer
# IPv6; this command performs only transactional deletes.
db_uri="$(vault kv get -field=DATABASE_SESSION_POOLER_URL "$VAULT_SUPABASE_PATH")"
[[ -n "$db_uri" ]] || { echo 'Supabase session pooler URI is empty' >&2; exit 1; }
mapfile -t db_parts < <(printf '%s' "$db_uri" | python3 -c 'import sys; from urllib.parse import unquote, urlsplit; u=urlsplit(sys.stdin.read()); print(u.hostname or ""); print(u.port or 5432); print(unquote(u.username or "")); print(unquote(u.password or "")); print((u.path or "/postgres").lstrip("/") or "postgres")')
[[ "${#db_parts[@]}" -eq 5 && -n "${db_parts[0]}" && -n "${db_parts[2]}" && -n "${db_parts[3]}" ]] || { echo 'Supabase session pooler URI is invalid' >&2; exit 1; }
export PGHOST="${db_parts[0]}" PGPORT="${db_parts[1]}" PGUSER="${db_parts[2]}" PGPASSWORD="${db_parts[3]}" PGDATABASE="${db_parts[4]}"
unset db_uri db_parts
export PGAPPNAME=xconnect-uat-overlay-reset
export PGCONNECT_TIMEOUT=15

printf '%s\n' 'Checking the exact UAT overlay tables (no data changed yet)...'
for table in "${OVERLAY_TABLES[@]}"; do
  exists="$(psql -X -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('public.${table}') IS NOT NULL")"
  [[ "$exists" == t ]] || { echo "Required overlay table is missing: $table" >&2; exit 1; }
done

printf '%s\n' 'Rows before reset:'
for table in "${OVERLAY_TABLES[@]}"; do
  count="$(psql -X -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM public.${table}")"
  printf '  %s=%s\n' "$table" "$count"
done

printf '%s\n' 'Transitional compatibility table state:'
for table in "${TRANSITIONAL_TABLES[@]}"; do
  exists="$(psql -X -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('public.${table}') IS NOT NULL")"
  if [[ "$exists" == t ]]; then
    count="$(psql -X -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM public.${table}")"
    printf '  %s=%s\n' "$table" "$count"
  else
    printf '  %s=ABSENT\n' "$table"
  fi
done

if (( check_only )); then
  printf '%s\n' 'UAT XConnect overlay check completed; no data changed.'
  exit 0
fi

psql -X -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '15s';
LOCK TABLE
  public.overlay_signed_config_acks,
  public.overlay_enrollment_sessions,
  public.overlay_device_credentials,
  public.overlay_registrations,
  public.overlay_devices,
  public.overlay_invites,
  public.overlay_networks
IN ACCESS EXCLUSIVE MODE;

-- Deliberately enumerate the overlay tables. Do not use schema-wide CASCADE:
-- users, application data, and future non-overlay tables must survive a UAT reset.
DELETE FROM public.overlay_signed_config_acks;
DELETE FROM public.overlay_enrollment_sessions;
DELETE FROM public.overlay_device_credentials;
DELETE FROM public.overlay_registrations;
DELETE FROM public.overlay_devices;
DELETE FROM public.overlay_invites;
DELETE FROM public.overlay_networks;
COMMIT;
SQL

printf '%s\n' 'Rows after reset:'
for table in "${OVERLAY_TABLES[@]}"; do
  count="$(psql -X -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM public.${table}")"
  printf '  %s=%s\n' "$table" "$count"
  [[ "$count" == 0 ]] || { echo "Overlay reset verification failed: $table is not empty" >&2; exit 1; }
done

if (( drop_transitional )); then
  psql -X -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '15s';
-- These tables are empty compatibility artifacts in UAT. Drop them without
-- CASCADE so a hidden dependency fails the transaction instead of removing
-- unrelated objects. The current deployed legacy handlers will need to be
-- removed or disabled before this option is used.
LOCK TABLE public.overlay_config_acks, public.overlay_nodes
IN ACCESS EXCLUSIVE MODE;
DROP TABLE public.overlay_config_acks, public.overlay_nodes;
COMMIT;
SQL
  for table in "${TRANSITIONAL_TABLES[@]}"; do
    exists="$(psql -X -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('public.${table}') IS NOT NULL")"
    [[ "$exists" == f ]] || { echo "Transitional table was not dropped: $table" >&2; exit 1; }
    printf '  dropped=%s\n' "$table"
  done
fi

printf '%s\n' 'UAT XConnect overlay reset completed; users, business tables, Vault records, and node-local WireGuard keys were not changed.'
unset PGPASSWORD
