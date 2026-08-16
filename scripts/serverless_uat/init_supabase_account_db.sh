#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the logical Accounts database on a Supabase project.
# Supabase Cloud exposes one PostgreSQL database named `postgres` per project;
# `account` is the Accounts service contract, not a second database to create.
# Project/password values are read from Vault and never printed.

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
ENV_NAME="${VAULT_ENV_PATH:-}"
SERVER_PATH=""
DATABASES_PATH=""
IAC_ROOT="${SUPABASE_IAC_ROOT:-}"
SCHEMA_FILE="${ACCOUNT_SCHEMA_FILE:-}"
DRY_RUN=0
FORCE=0
WRITE_ACCOUNT_PASSWORD=0

usage() {
  cat >&2 <<'EOF'
Usage:
  init_supabase_account_db.sh --env dev|sit|uat|prod [options]

Reads Supabase project/password from Vault KV v2:
  kv/<env>/serverless/supabase

Merges the Accounts connection contract into:
  kv/<env>/databases

Options:
  --env <env>                  Environment (also accepted via VAULT_ENV_PATH)
  --server-path <path>        Override the Supabase server KV path
  --databases-path <path>     Override the database KV path
  --iac-root <path>            iac_modules checkout containing supabase-cloud/
  --schema-file <path>        Accounts SQL schema to apply with psql
  --write-account-password    Also write account_pg_password for existing consumers
  --force                     Replace existing target keys
  --dry-run                   Read and validate, but do not init or write
  -h, --help                  Show this help

Vault source keys (configurable through environment):
  SUPABASE_PROJECT_REF_KEY       default PROJECT_REF
  SUPABASE_DATABASE_PASSWORD_KEY default DATABASE_PASSWORD
  SUPABASE_DATABASE_USERNAME_KEY default DATABASE_USERNAME (or URI user)
  SUPABASE_DATABASE_NAME_KEY     default DATABASE_NAME (or URI path)
  SUPABASE_DATABASE_URI_KEY      default DATABASE_DIRECT_URL
  SUPABASE_SESSION_URI_KEY       default DATABASE_SESSION_POOLER_URL
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) [ "$#" -ge 2 ] || { usage; exit 2; }; ENV_NAME="$2"; shift 2 ;;
    --server-path) [ "$#" -ge 2 ] || { usage; exit 2; }; SERVER_PATH="$2"; shift 2 ;;
    --databases-path) [ "$#" -ge 2 ] || { usage; exit 2; }; DATABASES_PATH="$2"; shift 2 ;;
    --iac-root) [ "$#" -ge 2 ] || { usage; exit 2; }; IAC_ROOT="$2"; shift 2 ;;
    --schema-file) [ "$#" -ge 2 ] || { usage; exit 2; }; SCHEMA_FILE="$2"; shift 2 ;;
    --write-account-password) WRITE_ACCOUNT_PASSWORD=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "${ENV_NAME}" in
  dev|sit|uat|prod) ;;
  *) echo "environment is required and must be dev, sit, uat, or prod" >&2; exit 2 ;;
esac

SERVER_PATH="${SERVER_PATH:-kv/${ENV_NAME}/serverless/supabase}"
DATABASES_PATH="${DATABASES_PATH:-kv/${ENV_NAME}/databases}"
PROJECT_REF_KEY="${SUPABASE_PROJECT_REF_KEY:-PROJECT_REF}"
PASSWORD_KEY="${SUPABASE_DATABASE_PASSWORD_KEY:-DATABASE_PASSWORD}"
USERNAME_KEY="${SUPABASE_DATABASE_USERNAME_KEY:-DATABASE_USERNAME}"
DATABASE_NAME_KEY="${SUPABASE_DATABASE_NAME_KEY:-DATABASE_NAME}"
DIRECT_URI_KEY="${SUPABASE_DATABASE_URI_KEY:-DATABASE_DIRECT_URL}"
SESSION_URI_KEY="${SUPABASE_SESSION_URI_KEY:-DATABASE_SESSION_POOLER_URL}"
ACCOUNT_SERVICE_NAME="${SUPABASE_ACCOUNT_SERVICE_NAME:-account}"

command -v vault >/dev/null 2>&1 || { echo "vault CLI is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
if [ -n "${IAC_ROOT}" ] && ! [ -x "${IAC_ROOT}/terraform-hcl-standard/supabase-cloud/scripts/init.sh" ]; then
  echo "Supabase IAC init script not found below --iac-root: ${IAC_ROOT}" >&2
  exit 2
fi
if [ -n "${SCHEMA_FILE}" ] && ! [ -f "${SCHEMA_FILE}" ]; then
  echo "schema file not found: ${SCHEMA_FILE}" >&2
  exit 2
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "VAULT_TOKEN is required for the Vault CLI" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/.supabase-account-vault.XXXXXX")"
chmod 700 "${tmp_dir}"
trap 'rm -f "${tmp_dir}/server.json" "${tmp_dir}/current.json" "${tmp_dir}/incoming.json" "${tmp_dir}/incoming.json.merged" "${tmp_dir}/to-write.json" "${tmp_dir}/secret-password.json" "${tmp_dir}/secret-account-password.json" "${tmp_dir}/secret-session.json" "${tmp_dir}/secret-direct.json"; rmdir "${tmp_dir}" 2>/dev/null || true' EXIT

vault kv get -format=json "${SERVER_PATH}" > "${tmp_dir}/server.json"
jq -e '.data.data | type == "object"' "${tmp_dir}/server.json" >/dev/null || {
  echo "Vault source is not a KV v2 object: ${SERVER_PATH}" >&2
  exit 1
}

get_secret() {
  local key="$1"
  jq -r --arg key "${key}" '.data.data[$key] // empty' "${tmp_dir}/server.json"
}

# Some Supabase connection-string views use `[YOUR-PASSWORD]` as a password
# placeholder, and some views wrap a DNS hostname in brackets. Python's
# urlsplit() rejects both forms in a netloc; normalize them before parsing.
# Valid IPv4/IPv6 host literals remain unchanged. The URI travels through
# stdin so the helper never exposes credentials as process arguments.
normalize_postgres_uri() {
  python3 -c '
import ipaddress
import re
import sys

value = sys.stdin.read()

# Brackets in the userinfo are a Supabase UI placeholder, not an IPv6 host.
value = re.sub(
    r"^([^?#]*://)([^@]*)@",
    lambda match: match.group(1) + match.group(2).replace("[", "").replace("]", "") + "@",
    value,
    count=1,
)

def normalize(match):
    host = match.group(1)
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return "@" + host + (match.group(2) or "")
    return match.group(0)

sys.stdout.write(re.sub(r"@\[([^]]+)\](?:(:\d+))?", normalize, value))
'
}

materialize_postgres_uri() {
  python3 -c '
import re
import sys
from urllib.parse import quote

uri, password = sys.stdin.buffer.read().split(b"\0", 1)
uri = uri.decode()
password = password.decode()
match = re.match(r"^([^?#]*://)([^@]*)@(.*)$", uri)
if match:
    prefix, userinfo, host_and_path = match.groups()
    if ":" in userinfo:
        username, uri_password = userinfo.rsplit(":", 1)
        if re.search(r"your[-_ ]password", uri_password, re.IGNORECASE):
            userinfo = username + ":" + quote(password, safe="")
            uri = prefix + userinfo + "@" + host_and_path
sys.stdout.write(uri)
'
}

is_placeholder_password() {
  python3 -c 'import re, sys; sys.exit(0 if re.search(r"your[-_ ]password", sys.stdin.read(), re.IGNORECASE) else 1)'
}

PROJECT_REF="$(get_secret "${PROJECT_REF_KEY}")"
DIRECT_URI="$(get_secret "${DIRECT_URI_KEY}")"
SESSION_URI="$(get_secret "${SESSION_URI_KEY}")"
DATABASE_PASSWORD="$(get_secret "${PASSWORD_KEY}")"
ACCOUNT_USERNAME="$(get_secret "${USERNAME_KEY}")"
ACCOUNT_DATABASE_NAME="$(get_secret "${DATABASE_NAME_KEY}")"

if [ -z "${PROJECT_REF}" ]; then
  echo "Vault source is missing ${PROJECT_REF_KEY}: ${SERVER_PATH}" >&2
  exit 1
fi
if [ -z "${DATABASE_PASSWORD}" ] && [ -z "${DIRECT_URI}" ]; then
  echo "Vault source must provide ${PASSWORD_KEY} or ${DIRECT_URI_KEY}: ${SERVER_PATH}" >&2
  exit 1
fi
if [ -z "${DATABASE_PASSWORD}" ]; then
  # Existing deployments keep the password inside the Vault URI. Extract it
  # through stdin so it never becomes a process argument or a log line.
  DATABASE_PASSWORD="$(printf '%s' "${DIRECT_URI}" | normalize_postgres_uri | python3 -c 'import sys; from urllib.parse import unquote, urlsplit; value = urlsplit(sys.stdin.read()).password; print(unquote(value or ""))')"
fi
if [ -z "${DATABASE_PASSWORD}" ]; then
  echo "Unable to obtain a database password from Vault source: ${SERVER_PATH}" >&2
  exit 1
fi
if printf '%s' "${DATABASE_PASSWORD}" | is_placeholder_password; then
  echo "Vault source contains a Supabase password placeholder; provide a real ${PASSWORD_KEY}" >&2
  exit 1
fi
if [ -z "${SESSION_URI}" ]; then
  SESSION_URI="${DIRECT_URI}"
fi
if [ -z "${SESSION_URI}" ]; then
  echo "Vault source is missing both ${SESSION_URI_KEY} and ${DIRECT_URI_KEY}: ${SERVER_PATH}" >&2
  exit 1
fi
SESSION_URI="$(printf '%s' "${SESSION_URI}" | normalize_postgres_uri)"
if [ -n "${DIRECT_URI}" ]; then
  DIRECT_URI="$(printf '%s' "${DIRECT_URI}" | normalize_postgres_uri)"
fi
SESSION_URI="$(printf '%s\0%s' "${SESSION_URI}" "${DATABASE_PASSWORD}" | materialize_postgres_uri)"
if [ -n "${DIRECT_URI}" ]; then
  DIRECT_URI="$(printf '%s\0%s' "${DIRECT_URI}" "${DATABASE_PASSWORD}" | materialize_postgres_uri)"
fi
if [ -z "${ACCOUNT_USERNAME}" ]; then
  ACCOUNT_USERNAME="$(printf '%s' "${SESSION_URI}" | normalize_postgres_uri | python3 -c 'import sys; from urllib.parse import unquote, urlsplit; print(unquote(urlsplit(sys.stdin.read()).username or ""))')"
fi
if [ -z "${ACCOUNT_DATABASE_NAME}" ]; then
  ACCOUNT_DATABASE_NAME="$(printf '%s' "${SESSION_URI}" | normalize_postgres_uri | python3 -c 'import sys; from urllib.parse import unquote, urlsplit; print(unquote((urlsplit(sys.stdin.read()).path or "/postgres").lstrip("/") or "postgres"))')"
fi
if [ -z "${ACCOUNT_USERNAME}" ] || [ -z "${ACCOUNT_DATABASE_NAME}" ]; then
  echo "Vault source must provide ${USERNAME_KEY}/${DATABASE_NAME_KEY} or a URI with user/database: ${SERVER_PATH}" >&2
  exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "would initialize Supabase project ${PROJECT_REF} for ${ENV_NAME}/${ACCOUNT_SERVICE_NAME}"
  echo "would read ${SERVER_PATH} and merge account connection keys into ${DATABASES_PATH}"
  exit 0
fi

if [ -n "${IAC_ROOT}" ]; then
  export SUPABASE_PROJECT_REF="${PROJECT_REF}"
  export SUPABASE_DATABASE_USERNAME="${ACCOUNT_USERNAME}"
  export SUPABASE_DATABASE_NAME="${ACCOUNT_DATABASE_NAME}"
  export TF_VAR_database_password="${DATABASE_PASSWORD}"
  if [ -n "${DIRECT_URI}" ]; then export SUPABASE_DATABASE_DIRECT_URL="${DIRECT_URI}"; fi
  echo "==> initialize Supabase Terraform workdir (${ENV_NAME})"
  (cd "${IAC_ROOT}/terraform-hcl-standard/supabase-cloud" && ./scripts/init.sh)
fi

if [ -n "${SCHEMA_FILE}" ]; then
  command -v psql >/dev/null 2>&1 || { echo "psql is required with --schema-file" >&2; exit 2; }
  # GitHub-hosted runners are IPv4-only in the common case. Session pooler
  # keeps psql/DDL reachable there; use Direct only when no session URI exists.
  schema_uri="${SESSION_URI:-${DIRECT_URI}}"
  connection_json="$(printf '%s' "${schema_uri}" | normalize_postgres_uri | python3 -c 'import json, sys; from urllib.parse import unquote, urlsplit; u = urlsplit(sys.stdin.read()); print(json.dumps({"host": u.hostname or "", "port": u.port or 5432, "user": unquote(u.username or ""), "database": (u.path or "/postgres").lstrip("/") or "postgres"}))')"
  db_host="$(printf '%s' "${connection_json}" | jq -r .host)"
  db_port="$(printf '%s' "${connection_json}" | jq -r .port)"
  db_user="$(printf '%s' "${connection_json}" | jq -r .user)"
  db_name="$(printf '%s' "${connection_json}" | jq -r .database)"
  [ -n "${db_host}" ] && [ -n "${db_user}" ] || { echo "invalid Supabase connection URI from Vault" >&2; exit 1; }
  echo "==> initialize Accounts schema in ${ENV_NAME} Supabase database"
  PGPASSWORD="${DATABASE_PASSWORD}" psql \
    -h "${db_host}" -p "${db_port}" -U "${db_user}" -d "${db_name}" \
    -v ON_ERROR_STOP=1 -f "${SCHEMA_FILE}" >/dev/null
fi

existing="$(vault kv get -format=json "${DATABASES_PATH}" 2>/dev/null || echo '{}')"
printf '%s' "${existing}" | jq '.data.data // {}' > "${tmp_dir}/current.json"

# Keep the existing VPS credential untouched unless explicitly requested.
# Secret values are piped to jq instead of being passed as process arguments.
jq -n \
  --arg ref "${PROJECT_REF}" --arg username "${ACCOUNT_USERNAME}" \
  --arg service "${ACCOUNT_SERVICE_NAME}" --arg database "${ACCOUNT_DATABASE_NAME}" \
  '{account_supabase_project_ref: $ref,
    account_database_username: $username,
    account_database_name: $database}' > "${tmp_dir}/incoming.json"
printf '%s' "${DATABASE_PASSWORD}" | jq -Rs '{account_supabase_database_password: .}' > "${tmp_dir}/secret-password.json"
printf '%s' "${SESSION_URI}" | jq -Rs '{account_database_uri: .}' > "${tmp_dir}/secret-session.json"
if [ -n "${DIRECT_URI}" ]; then
  printf '%s' "${DIRECT_URI}" | jq -Rs '{account_database_direct_uri: .}' > "${tmp_dir}/secret-direct.json"
else
  printf '{}' > "${tmp_dir}/secret-direct.json"
fi
jq -s 'add' "${tmp_dir}/incoming.json" "${tmp_dir}/secret-password.json" "${tmp_dir}/secret-session.json" "${tmp_dir}/secret-direct.json" > "${tmp_dir}/incoming.json.merged"
mv "${tmp_dir}/incoming.json.merged" "${tmp_dir}/incoming.json"
if [ "${WRITE_ACCOUNT_PASSWORD}" -eq 1 ]; then
  printf '%s' "${DATABASE_PASSWORD}" | jq -Rs '{account_pg_password: .}' > "${tmp_dir}/secret-account-password.json"
  jq -s 'add' "${tmp_dir}/incoming.json" "${tmp_dir}/secret-account-password.json" > "${tmp_dir}/incoming.json.merged"
  mv "${tmp_dir}/incoming.json.merged" "${tmp_dir}/incoming.json"
fi

jq -n \
  --slurpfile current "${tmp_dir}/current.json" \
  --slurpfile incoming "${tmp_dir}/incoming.json" --argjson force "${FORCE}" \
  '$incoming[0] | with_entries(select($force == 1 or (.key as $key | ($current[0] | has($key) | not))))' \
  > "${tmp_dir}/to-write.json"
if [ "$(jq -c . "${tmp_dir}/to-write.json")" = "{}" ]; then
  echo "skip ${DATABASES_PATH}: account Supabase keys already exist (use --force to replace)"
  exit 0
fi

jq -n --slurpfile current "${tmp_dir}/current.json" --slurpfile incoming "${tmp_dir}/to-write.json" \
  '$current[0] + $incoming[0]' | vault kv put "${DATABASES_PATH}" - >/dev/null

echo "wrote ${DATABASES_PATH}: $(jq -r 'keys | join(", ")' "${tmp_dir}/to-write.json")"
echo "done (secret values were not printed)"
