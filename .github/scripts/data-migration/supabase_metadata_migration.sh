#!/usr/bin/env bash
set -euo pipefail

# Export the current PostgreSQL public-schema metadata and, when requested,
# business rows to the configured Supabase project. This is deliberately
# separate from migratectl: migratectl moves Accounts rows between VPS hosts,
# while this path is the one-way VPS -> Supabase database cutover path.
# The target must use Supabase's direct endpoint or session pooler, never a
# transaction pooler URL, because pg_dump/DDL need a stable session.

SOURCE_DSN="${MIGRATION_SOURCE_DSN:-}"
TARGET_DSN="${SUPABASE_TARGET_DSN:-}"
EXPECTED_REF="${SUPABASE_EXPECTED_PROJECT_REF:-}"
VAULT_REF="${SUPABASE_VAULT_PROJECT_REF:-}"
DRY_RUN="${SUPABASE_METADATA_DRY_RUN:-true}"
MODE="${SUPABASE_MIGRATION_MODE:-metadata}"
CONNECTION_MODE="${SUPABASE_TARGET_CONNECTION_MODE:-session_pooler}"
SOURCE_TUNNEL_HOST="${SUPABASE_SOURCE_TUNNEL_HOST:-}"
SOURCE_TUNNEL_PORT="${SUPABASE_SOURCE_TUNNEL_PORT:-15433}"
SOURCE_TUNNEL_LOCAL_PORT="${SUPABASE_SOURCE_TUNNEL_LOCAL_PORT:-15433}"
DUMP_DIR="${SUPABASE_METADATA_DUMP_DIR:-${RUNNER_TEMP:-/tmp}/supabase-metadata-migration}"
SCHEMA_FILE="${DUMP_DIR}/public-schema.sql"
DATA_FILE="${DUMP_DIR}/public-data.sql"
APPLY_FILE="${DUMP_DIR}/apply.sql"
SOURCE_TUNNEL_CONFIG=""
SOURCE_TUNNEL_PID=""

cleanup() {
  if [[ -n "${SOURCE_TUNNEL_PID}" ]]; then
    kill "${SOURCE_TUNNEL_PID}" >/dev/null 2>&1 || true
    wait "${SOURCE_TUNNEL_PID}" 2>/dev/null || true
  fi
  [[ -z "${SOURCE_TUNNEL_CONFIG}" ]] || rm -f "${SOURCE_TUNNEL_CONFIG}"
  rm -rf "${DUMP_DIR}"
}
trap cleanup EXIT

redact_dsn() {
  printf '%s' "$1" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

if [[ -z "${SOURCE_DSN}" || -z "${TARGET_DSN}" ]]; then
  echo "ERROR: source and Supabase target DSNs are required from Vault." >&2
  exit 1
fi
source_uses_loopback=false
if [[ "${SOURCE_DSN}" =~ @((127\.0\.0\.1)|localhost|\[::1\])(:|/|\?) ]]; then
  source_uses_loopback=true
fi
if [[ -z "${VAULT_REF}" ]]; then
  echo "ERROR: Supabase Vault is missing PROJECT_REF." >&2
  exit 1
fi
if [[ -z "${EXPECTED_REF}" ]]; then
  EXPECTED_REF="$(printf '%s' "${TARGET_DSN}" | sed -nE 's#.*postgres\.([a-z0-9]+):.*@.*#\1#p')"
  if [[ -z "${EXPECTED_REF}" ]]; then
    EXPECTED_REF="$(printf '%s' "${TARGET_DSN}" | sed -nE 's#.*db\.([a-z0-9]+)\.supabase\.co.*#\1#p')"
  fi
fi
if [[ -z "${EXPECTED_REF}" || "${VAULT_REF}" != "${EXPECTED_REF}" ]]; then
  echo "ERROR: Supabase Vault PROJECT_REF does not match the requested project ref." >&2
  exit 1
fi
if [[ "${TARGET_DSN}" != *"supabase.com"* ]]; then
  echo "ERROR: target DSN is not a Supabase endpoint; refusing to write." >&2
  exit 1
fi
if [[ "${CONNECTION_MODE}" != "session_pooler" && "${CONNECTION_MODE}" != "direct" ]]; then
  echo "ERROR: SUPABASE_TARGET_CONNECTION_MODE must be session_pooler or direct." >&2
  exit 1
fi
if [[ "${TARGET_DSN}" == *"sslmode=disable"* ]]; then
  echo "ERROR: Supabase target connection must use TLS." >&2
  exit 1
fi
if [[ "${TARGET_DSN}" =~ :6543([/?]|$) ]]; then
  echo "ERROR: transaction pooler (port 6543) is not supported for pg_dump/DDL." >&2
  exit 1
fi
if [[ "${CONNECTION_MODE}" == "session_pooler" && "${TARGET_DSN}" != *"pooler.supabase.com"* ]]; then
  echo "ERROR: session_pooler mode requires a Supavisor session-pooler DSN." >&2
  exit 1
fi
if [[ "${CONNECTION_MODE}" == "direct" && "${TARGET_DSN}" == *"pooler.supabase.com"* ]]; then
  echo "ERROR: direct mode cannot use a Supabase pooler DSN." >&2
  exit 1
fi
if [[ "${TARGET_DSN}" == *"svc.plus"* || "${TARGET_DSN}" == "${SOURCE_DSN}" ]]; then
  echo "ERROR: target DSN is unsafe or identical to source; refusing to write." >&2
  exit 1
fi
if [[ "${MODE}" != "metadata" && "${MODE}" != "metadata_and_data" ]]; then
  echo "ERROR: SUPABASE_MIGRATION_MODE must be metadata or metadata_and_data." >&2
  exit 1
fi

command -v pg_dump >/dev/null || { echo "ERROR: pg_dump is required." >&2; exit 1; }
command -v psql >/dev/null || { echo "ERROR: psql is required." >&2; exit 1; }
if [[ "${source_uses_loopback}" == true ]]; then
  if [[ -z "${SOURCE_TUNNEL_HOST}" ]]; then
    echo "ERROR: MIGRATION_SOURCE_DSN targets runner loopback but SUPABASE_SOURCE_TUNNEL_HOST is not configured." >&2
    echo "       Configure a TLS tunnel target for the self-hosted PostgreSQL source." >&2
    exit 1
  fi
  if [[ ! "${SOURCE_DSN}" =~ :${SOURCE_TUNNEL_LOCAL_PORT}([/?]|$) ]]; then
    echo "ERROR: loopback source DSN must use SUPABASE_SOURCE_TUNNEL_LOCAL_PORT=${SOURCE_TUNNEL_LOCAL_PORT}." >&2
    exit 1
  fi
  command -v stunnel >/dev/null || { echo "ERROR: stunnel is required for a loopback migration source." >&2; exit 1; }
  SOURCE_TUNNEL_CONFIG="$(mktemp "${RUNNER_TEMP:-/tmp}/supabase-source-stunnel.XXXXXX.conf")"
  printf '%s\n' \
    'foreground = yes' \
    'client = yes' \
    '[source-postgres]' \
    "accept = 127.0.0.1:${SOURCE_TUNNEL_LOCAL_PORT}" \
    "connect = ${SOURCE_TUNNEL_HOST}:${SOURCE_TUNNEL_PORT}" \
    >"${SOURCE_TUNNEL_CONFIG}"
  stunnel "${SOURCE_TUNNEL_CONFIG}" >"${DUMP_DIR}.stunnel.log" 2>&1 &
  SOURCE_TUNNEL_PID="$!"
  for _ in {1..20}; do
    if kill -0 "${SOURCE_TUNNEL_PID}" >/dev/null 2>&1 && (echo >"/dev/tcp/127.0.0.1/${SOURCE_TUNNEL_LOCAL_PORT}") 2>/dev/null; then
      echo "Source PostgreSQL TLS tunnel ready: ${SOURCE_TUNNEL_HOST}:${SOURCE_TUNNEL_PORT}"
      break
    fi
    sleep 0.25
  done
  if ! kill -0 "${SOURCE_TUNNEL_PID}" >/dev/null 2>&1; then
    echo "ERROR: source PostgreSQL TLS tunnel terminated during startup." >&2
    cat "${DUMP_DIR}.stunnel.log" >&2 || true
    exit 1
  fi
fi
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "ERROR: sha256sum or shasum is required." >&2
    exit 1
  fi
}
mkdir -p "${DUMP_DIR}"

echo "Supabase one-way database migration"
echo "  source: $(redact_dsn "${SOURCE_DSN}")"
echo "  target: $(redact_dsn "${TARGET_DSN}")"
echo "  project: ${EXPECTED_REF}"
echo "  connection: ${CONNECTION_MODE}"
echo "  mode: ${MODE}"
echo "  dry-run: ${DRY_RUN}"

echo "[1/5] Exporting public-schema metadata only..."
pg_dump "${SOURCE_DSN}" \
  --schema-only \
  --schema=public \
  --no-owner \
  --no-privileges \
  --no-comments \
  --no-publications \
  --no-subscriptions \
  --file="${SCHEMA_FILE}"

if [[ ! -s "${SCHEMA_FILE}" ]]; then
  echo "ERROR: schema dump is empty." >&2
  exit 1
fi
if grep -Eq 'CREATE EXTENSION[^;]*pglogical|CREATE SCHEMA[^;]*pglogical' "${SCHEMA_FILE}"; then
  echo "ERROR: source dump contains pglogical objects; Supabase Cloud does not accept this replication extension." >&2
  exit 1
fi
for object in 'CREATE TABLE.*users' 'CREATE TABLE.*traffic_minute_buckets' 'CREATE TABLE.*billing_ledger'; do
  if ! grep -Eiq "${object}" "${SCHEMA_FILE}"; then
    echo "ERROR: required Accounts/Billing metadata is missing from the source dump: ${object}" >&2
    exit 1
  fi
done

schema_sha256="$(hash_file "${SCHEMA_FILE}")"
data_sha256="none"
if [[ "${MODE}" == "metadata_and_data" ]]; then
  echo "[2/5] Exporting public-schema business data only..."
  pg_dump "${SOURCE_DSN}" \
    --data-only \
    --schema=public \
    --no-owner \
    --no-privileges \
    --no-comments \
    --no-publications \
    --no-subscriptions \
    --file="${DATA_FILE}"
  if [[ ! -s "${DATA_FILE}" ]]; then
    echo "ERROR: business data dump is empty." >&2
    exit 1
  fi
  data_sha256="$(hash_file "${DATA_FILE}")"
else
  echo "[2/5] Metadata-only mode; business rows will not be exported."
fi

echo "[3/5] Target preflight (read-only)..."
existing_tables="$(psql "${TARGET_DSN}" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name NOT IN ('spatial_ref_sys');")"
echo "  existing public tables: ${existing_tables}"
echo "  schema sha256: ${schema_sha256}"
echo "  data sha256: ${data_sha256}"

expected_marker="${schema_sha256}:${data_sha256}"
existing_marker="$(psql "${TARGET_DSN}" -Atqc "SELECT COALESCE((SELECT source_schema_sha256 || ':' || source_data_sha256 FROM public.platform_schema_migration_markers WHERE component = 'accounts-billing-public-schema'), '') FROM (SELECT 1) AS probe;" 2>/dev/null || true)"
if [[ -n "${existing_marker}" ]]; then
  if [[ "${existing_marker}" == "${expected_marker}" ]]; then
    echo "  migration marker matches the source dump; target is already converged."
    exit 0
  fi
  echo "ERROR: target migration marker exists but does not match the source dump." >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[4/5] DRY_RUN=true; no target DDL or business data writes executed."
  echo "[5/5] Supabase metadata/data preflight completed."
  exit 0
fi

if [[ "${existing_tables}" != "0" ]]; then
  echo "ERROR: target public schema is not empty; refusing an implicit overwrite." >&2
  echo "       Review the target and rerun only after an explicit migration design." >&2
  exit 1
fi

echo "[4/5] Applying ${MODE} in one transaction..."
cp "${SCHEMA_FILE}" "${APPLY_FILE}"
if [[ "${MODE}" == "metadata_and_data" ]]; then
  cat "${DATA_FILE}" >> "${APPLY_FILE}"
fi
cat >> "${APPLY_FILE}" <<SQL
CREATE TABLE IF NOT EXISTS public.platform_schema_migration_markers (
  component TEXT PRIMARY KEY,
  source_schema_sha256 TEXT NOT NULL,
  source_data_sha256 TEXT NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.platform_schema_migration_markers (component, source_schema_sha256, source_data_sha256)
VALUES ('accounts-billing-public-schema', '${schema_sha256}', '${data_sha256}')
ON CONFLICT (component) DO UPDATE
SET source_schema_sha256 = EXCLUDED.source_schema_sha256,
    source_data_sha256 = EXCLUDED.source_data_sha256,
    applied_at = now();
SQL
psql "${TARGET_DSN}" -v ON_ERROR_STOP=1 --single-transaction --file="${APPLY_FILE}"

echo "[5/5] One-way Supabase migration completed for project ${EXPECTED_REF}."
