#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Database Release Checkpoint Restore Engine (Supabase Cloud & VPS PostgreSQL)
# ==============================================================================
# Atomically restores a database to a release-tag-bound backup checkpoint.
# Protected by explicit safety confirmation (CONFIRM_RESTORE=true).

TARGET_RELEASE_TAG="${TARGET_RELEASE_TAG:?TARGET_RELEASE_TAG is required}"
DATABASE_BACKEND="${DATABASE_BACKEND:-supabase}"
DATABASE_ENV="${DATABASE_ENV:-${VAULT_ENV_PATH:-uat}}"
DATABASE_NAME="${DATABASE_NAME:-account}"
CONFIRM_RESTORE="${CONFIRM_RESTORE:-false}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-${RUNNER_TEMP:-/tmp}/database-checkpoints/${TARGET_RELEASE_TAG}}"
WARM_LOCAL_DIR="/var/backups/checkpoints/${TARGET_RELEASE_TAG}"
TARGET_DSN="${SUPABASE_TARGET_DSN:-${TARGET_DSN:-}}"
CONTAINER_NAME="${VPS_CONTAINER_NAME:-postgresql-svc-plus}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-database-checkpoints}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
ENCRYPTION_PASS="${BACKUP_ENCRYPTION_PASS:-}"
LEDGER_TABLE="public.system_release_checkpoints"

redact_dsn() {
  printf '%s' "$1" | sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#'
}

if [[ "${CONFIRM_RESTORE}" != "true" ]]; then
  echo "ERROR: Refusing to restore checkpoint without explicit confirmation (CONFIRM_RESTORE=true)." >&2
  exit 1
fi

mkdir -p "${CHECKPOINT_DIR}"

pull_from_s3_if_needed() {
  local target_s3_uri="$1"
  local dest_file="$2"

  if [[ -s "${dest_file}" ]]; then
    return 0
  fi

  if [[ -n "${S3_BUCKET}" && -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "  pulling checkpoint from ${target_s3_uri}..."
    local s3_opts=()
    if [[ -n "${S3_ENDPOINT}" ]]; then
      s3_opts+=(--endpoint-url "${S3_ENDPOINT}")
    fi
    aws s3 cp "${target_s3_uri}" "${dest_file}" "${s3_opts[@]}" >/dev/null
    return 0
  fi
  return 1
}

# ==============================================================================
# Supabase Cloud Restore Handler
# ==============================================================================
restore_supabase() {
  echo "Restoring Supabase Cloud from release checkpoint ${TARGET_RELEASE_TAG}..."
  if [[ -z "${TARGET_DSN}" ]]; then
    echo "ERROR: TARGET_DSN or SUPABASE_TARGET_DSN is required for Supabase restore." >&2
    exit 1
  fi
  if [[ "${TARGET_DSN}" != *"supabase.com"* && "${TARGET_DSN}" != *"localhost"* && "${TARGET_DSN}" != *"127.0.0.1"* ]]; then
    echo "ERROR: Target DSN must be a Supabase connection endpoint." >&2
    exit 1
  fi

  echo "  target: $(redact_dsn "${TARGET_DSN}")"
  echo "  target_tag: ${TARGET_RELEASE_TAG} (env=${DATABASE_ENV})"

  local base_name="supabase_${DATABASE_ENV}_${TARGET_RELEASE_TAG}.sql"
  local raw_sql="${CHECKPOINT_DIR}/${base_name}"
  local gz_file="${raw_sql}.gz"
  local enc_file="${gz_file}.enc"

  if [[ ! -s "${raw_sql}" && ! -s "${gz_file}" && ! -s "${enc_file}" ]]; then
    local s3_uri="s3://${S3_BUCKET:-local}/${S3_PREFIX}/${DATABASE_ENV}/supabase/${TARGET_RELEASE_TAG}/$(basename "${enc_file}")"
    if ! pull_from_s3_if_needed "${s3_uri}" "${enc_file}"; then
      s3_uri="s3://${S3_BUCKET:-local}/${S3_PREFIX}/${DATABASE_ENV}/supabase/${TARGET_RELEASE_TAG}/$(basename "${gz_file}")"
      pull_from_s3_if_needed "${s3_uri}" "${gz_file}" || true
    fi
  fi

  # Decrypt if encrypted
  if [[ -s "${enc_file}" ]]; then
    [[ -n "${ENCRYPTION_PASS}" ]] || { echo "ERROR: ENCRYPTION_PASS is required to decrypt ${enc_file}." >&2; exit 1; }
    echo "  decrypting archive with AES-256-CBC..."
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
      -pass pass:"${ENCRYPTION_PASS}" -in "${enc_file}" -out "${gz_file}"
  fi

  if [[ -s "${gz_file}" ]]; then
    gunzip -c "${gz_file}" > "${raw_sql}"
  fi

  [[ -s "${raw_sql}" ]] || { echo "ERROR: Checkpoint file for tag ${TARGET_RELEASE_TAG} not found or empty." >&2; exit 1; }

  # Ensure CREATE SCHEMA public inside the dump does not collide if schema already exists
  sed -i.bak 's/CREATE SCHEMA public;/CREATE SCHEMA IF NOT EXISTS public;/g' "${raw_sql}"
  rm -f "${raw_sql}.bak"

  echo "  resetting public schema atomically..."
  psql "${TARGET_DSN}" -v ON_ERROR_STOP=1 -Atqc "
    DROP SCHEMA IF EXISTS public CASCADE;
    CREATE SCHEMA IF NOT EXISTS public;
    GRANT ALL ON SCHEMA public TO postgres;
    GRANT ALL ON SCHEMA public TO public;
  " >/dev/null

  echo "  importing checkpoint SQL dump..."
  psql "${TARGET_DSN}" -v ON_ERROR_STOP=1 -f "${raw_sql}" >/dev/null

  echo "  updating in-db ledger to rolled_back status..."
  psql "${TARGET_DSN}" -v ON_ERROR_STOP=1 -Atqc "
    INSERT INTO ${LEDGER_TABLE} 
      (release_tag, environment, database_backend, database_name, git_sha, status, completed_at)
    VALUES 
      ('${TARGET_RELEASE_TAG}', '${DATABASE_ENV}', 'supabase', 'postgres', 'unknown', 'rolled_back', NOW())
    ON CONFLICT (release_tag, environment, database_backend, database_name) 
    DO UPDATE SET status = 'rolled_back', completed_at = NOW();
  " >/dev/null

  rm -f "${raw_sql}"
  echo "Supabase successfully restored to release tag ${TARGET_RELEASE_TAG}."
}

# ==============================================================================
# VPS PostgreSQL Restore Handler
# ==============================================================================
restore_vps() {
  echo "Restoring VPS PostgreSQL from release checkpoint ${TARGET_RELEASE_TAG}..."
  command -v docker >/dev/null || { echo "ERROR: docker CLI is required for VPS restore." >&2; exit 1; }

  if ! docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    echo "ERROR: Target PostgreSQL container '${CONTAINER_NAME}' is not running." >&2
    exit 1
  fi

  local warm_dir="${WARM_LOCAL_DIR}"
  local globals_dump=""

  IFS=',' read -ra DBS <<< "${DATABASE_NAME}"
  for db in "${DBS[@]}"; do
    local dump_gz="${warm_dir}/${db}_${TARGET_RELEASE_TAG}.sql.gz"
    local dump_enc="${dump_gz}.enc"

    # Tier 1: Check local warm tier
    if [[ ! -s "${dump_gz}" && -s "${CHECKPOINT_DIR}/${db}_${TARGET_RELEASE_TAG}.sql.gz" ]]; then
      dump_gz="${CHECKPOINT_DIR}/${db}_${TARGET_RELEASE_TAG}.sql.gz"
    fi

    # Tier 2: Check remote S3 tier
    if [[ ! -s "${dump_gz}" ]]; then
      local s3_uri="s3://${S3_BUCKET:-local}/${S3_PREFIX}/${DATABASE_ENV}/vps-postgres/${TARGET_RELEASE_TAG}/$(basename "${dump_enc}")"
      if pull_from_s3_if_needed "${s3_uri}" "${dump_enc}"; then
        [[ -n "${ENCRYPTION_PASS}" ]] || { echo "ERROR: ENCRYPTION_PASS is required to decrypt ${dump_enc}." >&2; exit 1; }
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
          -pass pass:"${ENCRYPTION_PASS}" -in "${dump_enc}" -out "${dump_gz}"
      else
        s3_uri="s3://${S3_BUCKET:-local}/${S3_PREFIX}/${DATABASE_ENV}/vps-postgres/${TARGET_RELEASE_TAG}/$(basename "${dump_gz}")"
        pull_from_s3_if_needed "${s3_uri}" "${dump_gz}" || true
      fi
    fi

    [[ -s "${dump_gz}" ]] || { echo "ERROR: Checkpoint for database ${db} at tag ${TARGET_RELEASE_TAG} not found." >&2; exit 1; }

    echo "  re-creating database ${db}..."
    docker exec "${CONTAINER_NAME}" psql -U postgres -c "DROP DATABASE IF EXISTS \"${db}\"; CREATE DATABASE \"${db}\";" >/dev/null

    echo "  restoring database ${db} from checkpoint..."
    gunzip -c "${dump_gz}" | docker exec -i "${CONTAINER_NAME}" psql -U postgres -d "${db}" >/dev/null

    docker exec "${CONTAINER_NAME}" psql -U postgres -d "${db}" -Atqc "
      INSERT INTO ${LEDGER_TABLE} 
        (release_tag, environment, database_backend, database_name, git_sha, status, completed_at)
      VALUES 
        ('${TARGET_RELEASE_TAG}', '${DATABASE_ENV}', 'vps', '${db}', 'unknown', 'rolled_back', NOW())
      ON CONFLICT (release_tag, environment, database_backend, database_name) 
      DO UPDATE SET status = 'rolled_back', completed_at = NOW();
    " >/dev/null
  done

  # Restore globals if available
  if [[ -s "${warm_dir}/globals_${TARGET_RELEASE_TAG}.sql.gz" ]]; then
    echo "  restoring global roles/permissions..."
    gunzip -c "${warm_dir}/globals_${TARGET_RELEASE_TAG}.sql.gz" | docker exec -i "${CONTAINER_NAME}" psql -U postgres >/dev/null || true
  fi

  echo "VPS PostgreSQL successfully restored to release tag ${TARGET_RELEASE_TAG}."
}

case "${DATABASE_BACKEND}" in
  supabase)
    restore_supabase
    ;;
  vps)
    restore_vps
    ;;
  *)
    echo "ERROR: Unsupported DATABASE_BACKEND: ${DATABASE_BACKEND}. Allowed: supabase, vps." >&2
    exit 1
    ;;
esac
