#!/usr/bin/env bash
# Bootstrap the Shared ZITADEL secrets used by zitadel-server.yml.
#
# This helper only manages Vault KV v2 data. It never creates cloud resources,
# runs Terraform/Ansible/Doco-CD, changes DNS, or migrates an existing stack.
# Values are preserved by default; --generate-missing is required to create
# new random values for fields that are absent.
set -euo pipefail

vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
vault_mount="${VAULT_KV_MOUNT:-kv}"
iam_path="${ZITADEL_IAM_PATH:-shared/iam}"
database_path="${ZITADEL_DATABASE_PATH:-shared/databases}"
admin_key="${ZITADEL_ADMIN_KEY:-zitadel-admin@iam.svc.plus}"
mode="check"
generate_missing=0

usage() {
  sed -n '2,12p' "$0"
  cat <<'EOF'

Usage:
  bootstrap_zitadel_kv.sh --check
  bootstrap_zitadel_kv.sh --apply [--generate-missing]

Apply-only environment overrides:
  ZITADEL_MASTERKEY
  ZITADEL_ADMIN_PASSWORD
  ZITADEL_LOGIN_SESSION_COOKIE_SECRET
  POSTGRESQL_ADMIN_PASSWORD
  ZITADEL_PG_PASSWORD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode="check" ;;
    --apply) mode="apply" ;;
    --generate-missing) generate_missing=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ "${generate_missing}" -eq 1 && "${mode}" != "apply" ]]; then
  echo "--generate-missing requires --apply" >&2
  exit 1
fi
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || {
  echo "VAULT_ADDR must be an http(s) Vault URL" >&2
  exit 1
}
command -v vault >/dev/null 2>&1 || { echo "vault CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
if [[ "${generate_missing}" -eq 1 ]]; then
  command -v openssl >/dev/null 2>&1 || { echo "openssl is required for --generate-missing" >&2; exit 1; }
fi

VAULT_ADDR="${vault_addr}" vault token lookup >/dev/null 2>&1 || {
  echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
  exit 1
}

vault_read_or_empty() {
  local path="$1" current
  if current="$(VAULT_ADDR="${vault_addr}" vault kv get -mount="${vault_mount}" -format=json "${path}" 2>/dev/null)"; then
    printf '%s\n' "${current}"
  else
    printf '%s\n' '{"data":{"data":{}}}'
  fi
}

value_from() {
  local json="$1" key="$2" variable="$3" value
  value="${!variable:-}"
  if [[ -z "${value}" ]]; then
    value="$(jq -r --arg key "${key}" '.data.data[$key] // empty' <<<"${json}")"
  fi
  printf -v "${variable}" '%s' "${value}"
}

validate_required() {
  local label="$1" value="$2" minimum="$3"
  if [[ -z "${value}" || "${#value}" -lt "${minimum}" ]]; then
    missing_fields+=("${label}")
  fi
}

iam_json="$(vault_read_or_empty "${iam_path}")"
database_json="$(vault_read_or_empty "${database_path}")"
missing_fields=()

value_from "${iam_json}" masterkey ZITADEL_MASTERKEY
value_from "${iam_json}" "${admin_key}" ZITADEL_ADMIN_PASSWORD
value_from "${iam_json}" login_session_cookie_secret ZITADEL_LOGIN_SESSION_COOKIE_SECRET
value_from "${database_json}" postgres_root_password POSTGRESQL_ADMIN_PASSWORD
value_from "${database_json}" zitadel_pg_password ZITADEL_PG_PASSWORD

if [[ "${mode}" == "apply" && "${generate_missing}" -eq 1 ]]; then
  [[ -n "${ZITADEL_MASTERKEY}" ]] || ZITADEL_MASTERKEY="$(openssl rand -hex 16)"
  [[ -n "${ZITADEL_ADMIN_PASSWORD}" ]] || ZITADEL_ADMIN_PASSWORD="Zita$(openssl rand -hex 16)!a7"
  [[ -n "${ZITADEL_LOGIN_SESSION_COOKIE_SECRET}" ]] || ZITADEL_LOGIN_SESSION_COOKIE_SECRET="$(openssl rand -hex 32)"
  [[ -n "${POSTGRESQL_ADMIN_PASSWORD}" ]] || POSTGRESQL_ADMIN_PASSWORD="Pg$(openssl rand -hex 18)!b9"
  [[ -n "${ZITADEL_PG_PASSWORD}" ]] || ZITADEL_PG_PASSWORD="Zi$(openssl rand -hex 18)!c9"
fi

validate_required masterkey "${ZITADEL_MASTERKEY}" 32
if [[ -n "${ZITADEL_MASTERKEY}" && "${#ZITADEL_MASTERKEY}" -ne 32 ]]; then
  missing_fields+=(masterkey_exactly_32_characters)
fi
validate_required "${admin_key}" "${ZITADEL_ADMIN_PASSWORD}" 8
validate_required login_session_cookie_secret "${ZITADEL_LOGIN_SESSION_COOKIE_SECRET}" 32
validate_required postgres_root_password "${POSTGRESQL_ADMIN_PASSWORD}" 16
validate_required zitadel_pg_password "${ZITADEL_PG_PASSWORD}" 16

if [[ "${#missing_fields[@]}" -gt 0 ]]; then
  echo "Missing or invalid Shared ZITADEL KV fields: ${missing_fields[*]}" >&2
  if [[ "${mode}" == "check" ]]; then
    echo "Run --apply --generate-missing once, or provide explicit apply environment overrides." >&2
  else
    echo "Refusing to write incomplete Shared ZITADEL secrets." >&2
  fi
  exit 1
fi

echo "${iam_path}: required fields present"
echo "${database_path}: required fields present"

if [[ "${mode}" == "apply" ]]; then
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zitadel-kv.XXXXXX")"
  chmod 700 "${tmp_dir}"
  trap 'rm -rf "${tmp_dir}"' EXIT

  jq -n \
    --arg masterkey "${ZITADEL_MASTERKEY}" \
    --arg admin_key "${admin_key}" \
    --arg admin_password "${ZITADEL_ADMIN_PASSWORD}" \
    --arg cookie "${ZITADEL_LOGIN_SESSION_COOKIE_SECRET}" \
    '{masterkey:$masterkey, ($admin_key):$admin_password, login_session_cookie_secret:$cookie}' \
    >"${tmp_dir}/iam.json"
  jq -n \
    --arg root_password "${POSTGRESQL_ADMIN_PASSWORD}" \
    --arg zitadel_password "${ZITADEL_PG_PASSWORD}" \
    '{postgres_root_password:$root_password, zitadel_pg_password:$zitadel_password}' \
    >"${tmp_dir}/databases.json"

  VAULT_ADDR="${vault_addr}" vault kv put -mount="${vault_mount}" "${iam_path}" "@${tmp_dir}/iam.json" >/dev/null
  VAULT_ADDR="${vault_addr}" vault kv put -mount="${vault_mount}" "${database_path}" "@${tmp_dir}/databases.json" >/dev/null
  echo "Shared ZITADEL KV bootstrap applied: ${iam_path}, ${database_path}"
fi
