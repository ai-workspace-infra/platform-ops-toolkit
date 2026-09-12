#!/usr/bin/env bash
set -euo pipefail

# Emergency repair for accounts stranded with users.active = false.
#
# Background
#   Self-registration built store.User without setting Active, and
#   postgresStore.CreateUser always writes that column, so the schema default
#   (TRUE) never applied. Affected accounts log in successfully -- login does
#   not read users.active -- and are then refused by auth.RequireActiveUser on
#   every other endpoint with 403 account_suspended.
#   Fixed in ai-workspace-services/accounts#151. This script repairs the rows
#   written before that fix reached the environment.
#
# Why a blanket repair is arguable rather than a guess
#   One place in the accounts codebase deliberately deactivates a *user*: the
#   app-store review account in cmd/accountsvc/main.go, gated on its config
#   being disabled. (ensureDefaultBillingPlans sets BillingPlan.Active -- a
#   different entity.) Every other active = false row is the registration bug.
#   Pass that account through --exclude-email so the repair leaves it alone.
#
#   This stops being true once accounts#153 ships: activate/deactivate make
#   active = false a state an admin can legitimately set. After that, repair
#   individual accounts through the admin API instead of running this.
#
# Safety model
#   - Read-only by default. Writing requires --apply.
#   - Two phases: the rows are listed for review, then --apply updates exactly
#     the UUIDs that were listed. A row that turns inactive between the two
#     phases is not swept in silently; rerun to catch it.
#   - --max-rows aborts before writing if the set is larger than expected.
#   - Credentials are read from Vault and never printed.
#
# Usage
#   One account, which is the safer and longer-lived form:
#     scripts/repair_inactive_accounts.sh --env prod --email someone@example.com
#     scripts/repair_inactive_accounts.sh --env prod --email someone@example.com --apply
#
#   Every inactive account, excluding the app-store review account:
#     scripts/repair_inactive_accounts.sh --env prod --exclude-email review@example.com

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
export VAULT_ADDR
ENV_NAME="${VAULT_ENV_PATH:-}"
SERVER_PATH=""
APPLY=0
ASSUME_YES=0
MAX_ROWS=50
EXCLUDED=()
ONLY_EMAILS=()

usage() {
  cat >&2 <<'EOF'
Usage:
  repair_inactive_accounts.sh --env <dev|sit|uat|prod> [options]

Reads the Supabase connection from Vault KV v2:
  kv/<env>/serverless/supabase

Options:
  --env <env>              Environment (also accepted via VAULT_ENV_PATH)
  --server-path <path>     Override the Supabase server KV path
  --email <email>          Repair only this account. Repeatable. Without it
                           every inactive account is a candidate. Prefer this:
                           a targeted repair stays correct even after
                           accounts#153 makes active = false a legitimate
                           admin-set state, whereas the blanket form does not.
  --exclude-email <email>  Leave this account untouched. Repeatable.
                           Use it for the app-store review account, which is
                           deactivated on purpose. Unnecessary when --email
                           already names the accounts to repair.
  --max-rows <n>           Refuse to write if more rows than this need repair
                           (default 50). A larger set means something other
                           than the registration bug is at work -- stop and
                           investigate rather than mass-updating production.
  --apply                  WRITES TO THE DATABASE. Without it the script only
                           reports what it would change. You are asked to
                           confirm by typing the environment name before
                           anything is written; --yes skips that prompt for
                           non-interactive use.
  --yes                    Skip the confirmation prompt. Only meaningful with
                           --apply. Intended for a reviewed, scripted rerun --
                           not for the first run against an environment.
  -h, --help               Show this help

Before --apply, check that:
  - every row listed is an account you expect to reactivate
  - the diff shows only  active: f -> true
  - the app-store review account is NOT in the list (exclude it by email)

Context:
  Root cause fixed in  ai-workspace-services/accounts#151
  Admin activate/deactivate endpoints in  accounts#153 -- once those ship,
  active = false becomes a state an admin can legitimately set and this
  blanket repair is no longer safe to run. Repair single accounts through
  POST /admin/users/:userId/activate instead.
  Design review:  accounts  docs/architecture/auth-gates-and-rate-limits.md

Exit codes:
  0  nothing to repair, or repair completed
  1  refused to act (guard tripped, bad input, declined at the prompt)
  2  missing dependency
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --server-path) SERVER_PATH="${2:-}"; shift 2 ;;
    --email) ONLY_EMAILS+=("${2:-}"); shift 2 ;;
    --exclude-email) EXCLUDED+=("${2:-}"); shift 2 ;;
    --max-rows) MAX_ROWS="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

for cmd in vault jq psql python3; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "${cmd} is required" >&2; exit 2; }
done

[ -n "${ENV_NAME}" ] || { echo "--env is required" >&2; usage; exit 1; }
case "${ENV_NAME}" in
  dev|sit|uat|prod) ;;
  *) echo "unsupported --env: ${ENV_NAME}" >&2; exit 1 ;;
esac
[[ "${MAX_ROWS}" =~ ^[0-9]+$ ]] || { echo "--max-rows must be a non-negative integer" >&2; exit 1; }
SERVER_PATH="${SERVER_PATH:-kv/${ENV_NAME}/serverless/supabase}"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/.repair-inactive.XXXXXX")"
chmod 700 "${tmp_dir}"
trap 'rm -rf "${tmp_dir}"' EXIT

vault kv get -format=json "${SERVER_PATH}" > "${tmp_dir}/server.json"
jq -e '.data.data | type == "object"' "${tmp_dir}/server.json" >/dev/null || {
  echo "Vault source is not a KV v2 object: ${SERVER_PATH}" >&2
  exit 1
}

get_secret() {
  jq -r --arg key "$1" '.data.data[$key] // empty' "${tmp_dir}/server.json"
}

DATABASE_PASSWORD="$(get_secret DATABASE_PASSWORD)"
# Session pooler first: it is reachable from IPv4-only hosts, where the direct
# endpoint often is not. Direct is the fallback when no pooler URI is stored.
CONNECT_URI="$(get_secret DATABASE_SESSION_POOLER_URL)"
[ -n "${CONNECT_URI}" ] || CONNECT_URI="$(get_secret DATABASE_DIRECT_URL)"
[ -n "${CONNECT_URI}" ] || { echo "no Supabase connection URI in ${SERVER_PATH}" >&2; exit 1; }
[ -n "${DATABASE_PASSWORD}" ] || { echo "no DATABASE_PASSWORD in ${SERVER_PATH}" >&2; exit 1; }

connection_json="$(printf '%s' "${CONNECT_URI}" | python3 -c '
import json, sys
from urllib.parse import unquote, urlsplit
u = urlsplit(sys.stdin.read().strip())
print(json.dumps({
    "host": u.hostname or "",
    "port": u.port or 5432,
    "user": unquote(u.username or ""),
    "database": (u.path or "/postgres").lstrip("/") or "postgres",
}))')"
db_host="$(printf '%s' "${connection_json}" | jq -r .host)"
db_port="$(printf '%s' "${connection_json}" | jq -r .port)"
db_user="$(printf '%s' "${connection_json}" | jq -r .user)"
db_name="$(printf '%s' "${connection_json}" | jq -r .database)"
[ -n "${db_host}" ] && [ -n "${db_user}" ] || { echo "invalid Supabase connection URI from Vault" >&2; exit 1; }

run_psql() {
  PGPASSWORD="${DATABASE_PASSWORD}" psql \
    -h "${db_host}" -p "${db_port}" -U "${db_user}" -d "${db_name}" \
    -v ON_ERROR_STOP=1 --no-psqlrc "$@"
}

# Excluded emails travel as one delimited value and are compared
# case-insensitively in SQL, so no shell-side quoting of addresses is needed.
excluded_csv=""
if [ "${#EXCLUDED[@]}" -gt 0 ]; then
  excluded_csv="$(printf '%s\n' "${EXCLUDED[@]}" | paste -sd, -)"
fi

# An empty --email list means "every inactive account is a candidate"; the SQL
# below treats the empty string that way rather than as a filter matching
# nothing.
only_csv=""
if [ "${#ONLY_EMAILS[@]}" -gt 0 ]; then
  only_csv="$(printf '%s\n' "${ONLY_EMAILS[@]}" | paste -sd, -)"
fi

echo "==> ${ENV_NAME}: accounts at ${db_host} (user ${db_user}, db ${db_name})"
if [ -n "${only_csv}" ]; then
  echo "    repairing only: ${only_csv}"
else
  echo "    scope: every inactive account"
fi
if [ -n "${excluded_csv}" ]; then
  echo "    excluding: ${excluded_csv}"
elif [ -z "${only_csv}" ]; then
  echo "    excluding: (none) -- pass --exclude-email for the review account if it exists here"
fi

# Phase 1: show the rows a repair would touch, as a field-level diff. No
# password or secret column is selected anywhere in this script; this is the
# record the operator reviews before anything is written.
run_psql -v excluded="${excluded_csv}" -v only="${only_csv}" -P pager=off <<'SQL'
\echo ''
\echo 'Accounts currently inactive:'
SELECT uuid, email, username, created_at, updated_at
FROM users
WHERE active = false
  AND lower(email) <> ALL (
        SELECT lower(trim(value))
        FROM unnest(string_to_array(:'excluded', ',')) AS value
        WHERE trim(value) <> ''
      )
  AND (
        :'only' = ''
        OR lower(email) = ANY (
             SELECT lower(trim(value))
             FROM unnest(string_to_array(:'only', ',')) AS value
             WHERE trim(value) <> ''
           )
      )
ORDER BY created_at;

\echo ''
\echo 'Field-level diff this repair would produce:'
SELECT email, 'active' AS field, active::text AS before, 'true' AS after
FROM users
WHERE active = false
  AND lower(email) <> ALL (
        SELECT lower(trim(value))
        FROM unnest(string_to_array(:'excluded', ',')) AS value
        WHERE trim(value) <> ''
      )
  AND (
        :'only' = ''
        OR lower(email) = ANY (
             SELECT lower(trim(value))
             FROM unnest(string_to_array(:'only', ',')) AS value
             WHERE trim(value) <> ''
           )
      )
ORDER BY created_at;
\echo '(plus updated_at and version, which the database maintains on any write;'
\echo ' no other column may change -- enforced in the transaction, see below)'
SQL

target_uuids="$(run_psql -v excluded="${excluded_csv}" -v only="${only_csv}" -At <<'SQL'
SELECT uuid
FROM users
WHERE active = false
  AND lower(email) <> ALL (
        SELECT lower(trim(value))
        FROM unnest(string_to_array(:'excluded', ',')) AS value
        WHERE trim(value) <> ''
      )
  AND (
        :'only' = ''
        OR lower(email) = ANY (
             SELECT lower(trim(value))
             FROM unnest(string_to_array(:'only', ',')) AS value
             WHERE trim(value) <> ''
           )
      )
ORDER BY created_at;
SQL
)"

if [ -z "${target_uuids}" ]; then
  echo "==> nothing to repair"
  exit 0
fi

target_count="$(printf '%s\n' "${target_uuids}" | grep -c .)"
echo "==> ${target_count} account(s) would be reactivated"

if [ "${target_count}" -gt "${MAX_ROWS}" ]; then
  echo "refusing: ${target_count} rows exceeds --max-rows ${MAX_ROWS}." >&2
  echo "A set this large is not the registration bug alone. Investigate before writing." >&2
  exit 1
fi

# Every value is a uuid column read back from this same database moments ago,
# but validate the shape anyway: it is the only thing interpolated into SQL.
while IFS= read -r candidate; do
  [ -n "${candidate}" ] || continue
  [[ "${candidate}" =~ ^[0-9a-fA-F-]{36}$ ]] || {
    echo "refusing: unexpected uuid shape from the database: ${candidate}" >&2
    exit 1
  }
done <<< "${target_uuids}"

if [ "${APPLY}" -ne 1 ]; then
  echo "==> dry run. Re-run with --apply to reactivate exactly the accounts listed above."
  exit 0
fi

# Last stop before writing. The prompt asks for the environment name rather
# than a bare y/n: on a tired afternoon "yes" is muscle memory, "prod" is a
# deliberate act. --yes is for a rerun of something already reviewed.
if [ "${ASSUME_YES}" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "refusing: --apply needs a terminal to confirm on, or --yes to skip the prompt." >&2
    exit 1
  fi
  echo ""
  echo "About to set active = true on ${target_count} account(s) in ${ENV_NAME}."
  echo "Check the diff above shows only  active: f -> true , and that the"
  echo "app-store review account is not in the list."
  printf "Type the environment name (%s) to proceed: " "${ENV_NAME}"
  read -r confirmation
  if [ "${confirmation}" != "${ENV_NAME}" ]; then
    echo "==> declined, nothing written"
    exit 1
  fi
fi

uuid_values="$(printf '%s\n' "${target_uuids}" | sed "s/^/('/; s/\$/')/" | paste -sd, -)"

# The update targets the reviewed UUIDs rather than re-evaluating the
# predicate, so a row that turned inactive since phase 1 is left for the next
# run instead of being swept in unreviewed. The guard makes the transaction
# self-checking: if the resulting state differs from what was reviewed,
# nothing commits.
run_psql -P pager=off <<SQL
BEGIN;

CREATE TEMP TABLE repair_scope (uuid uuid PRIMARY KEY) ON COMMIT DROP;
INSERT INTO repair_scope (uuid) VALUES ${uuid_values};

-- Full-row snapshot, minus the secret columns, so "only active changed" is a
-- checked invariant rather than a claim. Any trigger, default, or rule that
-- touches another column shows up in the comparison below and aborts.
CREATE TEMP TABLE repair_before ON COMMIT DROP AS
SELECT u.uuid,
       to_jsonb(u) - 'password' - 'mfa_totp_secret' AS snap
FROM users u
JOIN repair_scope s ON s.uuid = u.uuid;

UPDATE users u
SET active = true
FROM repair_scope s
WHERE u.uuid = s.uuid AND u.active = false;

\echo ''
\echo 'Applied diff:'
SELECT b.snap->>'email' AS email,
       d.k              AS field,
       b.snap->>d.k     AS before,
       (to_jsonb(u) - 'password' - 'mfa_totp_secret')->>d.k AS after
FROM repair_before b
JOIN users u ON u.uuid = b.uuid
CROSS JOIN LATERAL (
  SELECT k
  FROM jsonb_object_keys(b.snap) AS t(k)
  WHERE b.snap->k
        IS DISTINCT FROM (to_jsonb(u) - 'password' - 'mfa_totp_secret')->k
) AS d
ORDER BY email, field;

DO \$guard\$
DECLARE
  expected integer := ${target_count};
  actual   integer;
  strayed  text;
BEGIN
  SELECT count(*) INTO actual
  FROM users u JOIN repair_scope s ON s.uuid = u.uuid
  WHERE u.active = true;
  IF actual <> expected THEN
    RAISE EXCEPTION 'guard: % of % reviewed accounts are active after update; rolling back', actual, expected;
  END IF;

  SELECT string_agg(DISTINCT d.k, ', ') INTO strayed
  FROM repair_before b
  JOIN users u ON u.uuid = b.uuid
  CROSS JOIN LATERAL (
    SELECT k
    FROM jsonb_object_keys(b.snap) AS t(k)
    WHERE b.snap->k
          IS DISTINCT FROM (to_jsonb(u) - 'password' - 'mfa_totp_secret')->k
  ) AS d
  -- active is the intended change. updated_at and version are row bookkeeping
  -- the database maintains on any write (there is a trigger on users doing
  -- exactly that), so they move on a legitimate repair too. Anything else
  -- means the write touched something it was not asked to.
  WHERE d.k NOT IN ('active', 'updated_at', 'version');

  IF strayed IS NOT NULL THEN
    RAISE EXCEPTION 'guard: repair also modified %; rolling back', strayed;
  END IF;
END
\$guard\$;

COMMIT;
SQL

echo "==> reactivated ${target_count} account(s) in ${ENV_NAME}"
echo "    verify: the affected users should now reach /api/auth/session with 200"
