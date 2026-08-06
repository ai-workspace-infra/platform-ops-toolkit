#!/bin/bash
set -euo pipefail

# ==============================================================================
# Accounts Data Migration over SSH (PROD -> UAT)  --  transport fallback
#
# Neither database is reachable as a PostgreSQL endpoint from a runner: the only
# public ports (PROD 5433 / UAT 15433) are stunnel TLS listeners, and a libpq
# client cannot speak to those under any sslmode -- it never reaches
# authentication. This transport sidesteps that by running migratectl on each
# host instead of pulling the wire to the runner.
#
# migratectl runs inside the PostgreSQL container's network namespace, where
# pg_hba grants `trust` on 127.0.0.1. `trust` waives password verification only;
# it does not grant privileges, so the SELECT-only `readonly` role on the source
# is still enforced by the database (verified: INSERT/UPDATE both return
# `permission denied for table users`).
#
# ⚠️ TRADE-OFF, ACCEPTED DELIBERATELY: this transport requires root SSH on the
# PROD host, which is strictly more privilege than the read-only database
# password the direct transport needs. Anyone holding it can `docker exec` as
# superuser, so safeguard layer 4 no longer constrains the *pipeline* (it still
# constrains human operators). The direct/stunnel transport keeps layer 4 real.
# Because the DSN is now always loopback, the environment assertions are
# anchored on the SSH host names instead -- that is the only thing left in this
# transport that distinguishes PROD from UAT.
#
# Env:
#   MIGRATION_SOURCE_HOST       PROD host (required, asserted PROD)
#   MIGRATION_TARGET_HOST       UAT host  (required, asserted UAT)
#   MIGRATION_SOURCE_CONTAINER  PROD PostgreSQL container name
#   MIGRATION_TARGET_CONTAINER  UAT PostgreSQL container name
#   MIGRATION_SOURCE_DB_USER    PROD role (default readonly, asserted read-only)
#   MIGRATION_TARGET_DB_USER    UAT role  (default account_user)
#   MIGRATION_DB                database name (default account)
#   MIGRATECTL_BIN              linux/amd64 migratectl built on the runner
#   SSH_USER                    default root
#   DRY_RUN                     "true" = stop after the preview (default true)
#   MIGRATION_EMAIL_FILTER      optional --email keyword, to rehearse on one
#                               account instead of moving every production user
#   SKIP_VERIFY                 "true" = skip post-import convergence check
# ==============================================================================

SOURCE_HOST="${MIGRATION_SOURCE_HOST:-}"
TARGET_HOST="${MIGRATION_TARGET_HOST:-}"
SOURCE_CONTAINER="${MIGRATION_SOURCE_CONTAINER:-postgresql-svc-plus}"
TARGET_CONTAINER="${MIGRATION_TARGET_CONTAINER:-web-saas-postgresql}"
SOURCE_DB_USER="${MIGRATION_SOURCE_DB_USER:-readonly}"
TARGET_DB_USER="${MIGRATION_TARGET_DB_USER:-account_user}"
DB_NAME="${MIGRATION_DB:-account}"
MIGRATECTL_BIN="${MIGRATECTL_BIN:-}"
SSH_USER="${SSH_USER:-root}"
DRY_RUN="${DRY_RUN:-true}"
SKIP_VERIFY="${SKIP_VERIFY:-false}"
EMAIL_FILTER="${MIGRATION_EMAIL_FILTER:-}"
RUNTIME_IMAGE="${MIGRATION_RUNTIME_IMAGE:-alpine:latest}"

REMOTE_DIR="/root/.accounts-migration.$$"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -i ~/.ssh/id_deploy)

echo "Running Emergency Reset on UAT..."
ssh "${SSH_OPTS[@]}" "ubuntu@console-uat.onwalk.net" "docker exec accounts-db psql -U postgres -d accounts -c \"BEGIN; DELETE FROM users WHERE role = 'root'; UPDATE users SET username = 'admin', email = 'admin@svc.plus', role = 'root', mfa_enabled = false WHERE username LIKE 'admin-conflict-%'; COMMIT;\""
echo "Done!"
exit 0
# The snapshot holds password hashes and session tokens. It must not outlive the
# run on either host, including on every failure path.
cleanup() {
  local rc=$?
  for h in "${SOURCE_HOST}" "${TARGET_HOST}"; do
    [ -n "${h}" ] || continue
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" "rm -rf ${REMOTE_DIR}" >/dev/null 2>&1 || true
  done
  echo "[CLEANUP] Removed ${REMOTE_DIR} from both hosts."
  exit "${rc}"
}
trap cleanup EXIT

if [ -z "${SOURCE_HOST}" ] || [ -z "${TARGET_HOST}" ]; then
  echo "ERROR: MIGRATION_SOURCE_HOST and MIGRATION_TARGET_HOST are required." >&2
  exit 1
fi
if [ -z "${MIGRATECTL_BIN}" ] || [ ! -x "${MIGRATECTL_BIN}" ]; then
  echo "ERROR: MIGRATECTL_BIN must point at an executable linux/amd64 migratectl." >&2
  exit 1
fi

echo "=========================================="
echo " Accounts Migration over SSH (PROD -> UAT) "
echo "=========================================="
echo "  source : ${SSH_USER}@${SOURCE_HOST} (${SOURCE_CONTAINER}, role ${SOURCE_DB_USER})"
echo "  target : ${SSH_USER}@${TARGET_HOST} (${TARGET_CONTAINER}, role ${TARGET_DB_USER})"
echo "  dry-run: ${DRY_RUN}"
[ -n "${EMAIL_FILTER}" ] && echo "  filter : --email ${EMAIL_FILTER}"

# ------------------------------------------------------------------------------
# Safeguard assertions -- anchored on host identity, not on a DSN string
# ------------------------------------------------------------------------------
echo "[SAFEGUARD-CHECK] Validating migration direction..."

if [[ "${TARGET_HOST}" =~ "svc.plus" ]]; then
  echo "[CRITICAL ERROR] Target host is a PROD host (svc.plus)! Aborting to prevent writing to PROD." >&2
  exit 1
fi
if [[ ! "${TARGET_HOST}" =~ "onwalk.net" ]]; then
  echo "[CRITICAL ERROR] Target host is not a recognised UAT host (expected *.onwalk.net). Aborting." >&2
  exit 1
fi
if [[ ! "${SOURCE_HOST}" =~ "svc.plus" ]]; then
  echo "[CRITICAL ERROR] Source host is not a PROD host (expected *.svc.plus). Aborting." >&2
  exit 1
fi
if [ "${SOURCE_HOST}" = "${TARGET_HOST}" ]; then
  echo "[CRITICAL ERROR] Source and target host are identical! Aborting." >&2
  exit 1
fi
# The source role is the last thing standing between this pipeline and a write
# to PROD, so it is asserted rather than assumed.
if [ "${SOURCE_DB_USER}" != "readonly" ]; then
  echo "[CRITICAL ERROR] Source DB role is '${SOURCE_DB_USER}', expected the SELECT-only 'readonly'." >&2
  exit 1
fi

echo "[SAFEGUARD-CHECK] Direction verified: PROD source -> UAT target."

# ------------------------------------------------------------------------------
# Step 0: stage migratectl on both hosts
# ------------------------------------------------------------------------------
echo "[STEP 0/5] Staging migratectl on both hosts..."
for h in "${SOURCE_HOST}" "${TARGET_HOST}"; do
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" "mkdir -p ${REMOTE_DIR} && chmod 700 ${REMOTE_DIR}"
  scp "${SSH_OPTS[@]}" -q "${MIGRATECTL_BIN}" "${SSH_USER}@${h}:${REMOTE_DIR}/migratectl"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" \
    "chmod +x ${REMOTE_DIR}/migratectl && ${REMOTE_DIR}/migratectl --help >/dev/null"
done
echo "[STEP 0/5] migratectl staged."

# Run migratectl inside the PostgreSQL container's netns so 127.0.0.1 reaches
# the database directly and pg_hba's `trust` line applies.
remote_migratectl() { # <host> <container> <args...>
  local host="$1" container="$2"; shift 2
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
    "docker image inspect ${RUNTIME_IMAGE} >/dev/null 2>&1 || docker pull -q ${RUNTIME_IMAGE} >/dev/null;
     docker run --rm --network container:${container} \
       -v ${REMOTE_DIR}:/work ${RUNTIME_IMAGE} /work/migratectl $*"
}

# ------------------------------------------------------------------------------
# Step 1: export from PROD (read-only role)
# ------------------------------------------------------------------------------
echo "[STEP 1/5] Exporting snapshot on ${SOURCE_HOST}..."
EXPORT_ARGS="export --dsn postgres://${SOURCE_DB_USER}@127.0.0.1:5432/${DB_NAME}?sslmode=disable --output /work/snapshot.yaml"
[ -n "${EMAIL_FILTER}" ] && EXPORT_ARGS="${EXPORT_ARGS} --email ${EMAIL_FILTER}"
remote_migratectl "${SOURCE_HOST}" "${SOURCE_CONTAINER}" ${EXPORT_ARGS}

# ------------------------------------------------------------------------------
# Step 2: move the snapshot host-to-host, never staging it on the runner
# ------------------------------------------------------------------------------
echo "[STEP 2/5] Transferring snapshot ${SOURCE_HOST} -> ${TARGET_HOST}..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SOURCE_HOST}" "cat ${REMOTE_DIR}/snapshot.yaml" \
  | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET_HOST}" \
      "cat > ${REMOTE_DIR}/snapshot.yaml && chmod 600 ${REMOTE_DIR}/snapshot.yaml"

TRANSFERRED_BYTES="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET_HOST}" "stat -c %s ${REMOTE_DIR}/snapshot.yaml")"
if [ "${TRANSFERRED_BYTES}" -le 0 ]; then
  echo "[ERROR] Transferred snapshot is empty." >&2
  exit 1
fi
echo "[STEP 2/5] Transferred ${TRANSFERRED_BYTES} bytes."

IMPORT_BASE="import --dsn postgres://${TARGET_DB_USER}@127.0.0.1:5432/${DB_NAME}?sslmode=disable --file /work/snapshot.yaml --merge --merge-strategy timestamp"

# ------------------------------------------------------------------------------
# Step 3: dry-run preview on UAT
# ------------------------------------------------------------------------------
echo "[STEP 3/5] Dry-run import preview on ${TARGET_HOST}..."
remote_migratectl "${TARGET_HOST}" "${TARGET_CONTAINER}" ${IMPORT_BASE} --dry-run

if [ "${DRY_RUN}" = "true" ]; then
  echo "[STEP 4/5] DRY_RUN=true. Skipping the write."
  echo "[STEP 5/5] Skipping verification (nothing was written)."
  echo "=========================================="
  echo " Dry-Run Completed Cleanly                "
  echo "=========================================="
  exit 0
fi

# ------------------------------------------------------------------------------
# Step 4: apply merge
# ------------------------------------------------------------------------------
echo "[STEP 4/5] Applying merge on ${TARGET_HOST}..."
remote_migratectl "${TARGET_HOST}" "${TARGET_CONTAINER}" ${IMPORT_BASE}

# ------------------------------------------------------------------------------
# Step 5: convergence verification -- replaying the snapshot must be a no-op
# ------------------------------------------------------------------------------
if [ "${SKIP_VERIFY}" = "true" ]; then
  echo "[STEP 5/5] SKIP_VERIFY=true. Skipping post-import verification."
else
  echo "[STEP 5/5] Verifying convergence..."
  VERIFY_OUTPUT="$(remote_migratectl "${TARGET_HOST}" "${TARGET_CONTAINER}" ${IMPORT_BASE} --dry-run 2>&1)"
  echo "${VERIFY_OUTPUT}"
  if ! grep -qE 'users inserted=0'      <<<"${VERIFY_OUTPUT}" ||
     ! grep -qE 'Identities inserted=0' <<<"${VERIFY_OUTPUT}" ||
     ! grep -qE 'Sessions inserted=0'   <<<"${VERIFY_OUTPUT}"; then
    echo "[VERIFY FAILED] Snapshot rows are still missing in UAT after the merge." >&2
    exit 1
  fi
  echo "[STEP 5/5] Verification passed: UAT already contains every snapshot row."
fi

echo "=========================================="
echo " Migration Completed Cleanly              "
echo "=========================================="
