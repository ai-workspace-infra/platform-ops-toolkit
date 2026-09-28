#!/usr/bin/env bash
set -euo pipefail

# Initialize or verify the shared Terraform S3-compatible backend contract.
# Secret values are read from the environment, written through a 0600 temp file,
# and never included in CLI arguments or output.

vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
secret_path="CICD/shared/iac_state"
action="${SHARED_IAC_STATE_ACTION:-check}"

while (($#)); do
  case "$1" in
    --check) action=check ;;
    --write) action=write ;;
    -h|--help)
      printf 'Usage: %s [--check|--write]\n' "$0"
      printf 'Reads/writes only kv/CICD/shared/iac_state; default action is check.\n'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "${action}" in
  check|write) ;;
  *) echo "SHARED_IAC_STATE_ACTION must be check or write" >&2; exit 2 ;;
esac
[[ "${vault_addr}" =~ ^https://[^/]+/?$ ]] || {
  echo "VAULT_ADDR must be an https:// Vault URL" >&2
  exit 2
}
command -v vault >/dev/null 2>&1 || { echo "vault CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
export VAULT_ADDR="${vault_addr}"
if [[ -z "${VAULT_TOKEN:-}" ]] && ! vault token lookup >/dev/null 2>&1; then
  echo "Vault authentication is required; use an authorized admin CLI session or VAULT_TOKEN." >&2
  exit 1
fi

required_fields=(
  TF_STATE_ENDPOINT
  TF_STATE_BUCKET
  TF_STATE_REGION
  TF_STATE_ACCESS_KEY
  TF_STATE_SECRET_KEY
)

if [[ "${action}" == write ]]; then
  for field in "${required_fields[@]}"; do
    if [[ -z "${!field:-}" ]]; then
      echo "${field} must be set in the environment before writing ${secret_path}" >&2
      exit 1
    fi
  done
  [[ "${TF_STATE_ENDPOINT}" =~ ^https://[^[:space:]]+$ ]] || {
    echo "TF_STATE_ENDPOINT must be an https:// URL" >&2
    exit 1
  }

  payload_file="$(mktemp "${TMPDIR:-/tmp}/shared-iac-state.XXXXXX")"
  chmod 600 "${payload_file}"
  trap 'rm -f "${payload_file}"' EXIT
  jq -n '{
    TF_STATE_ENDPOINT: env.TF_STATE_ENDPOINT,
    TF_STATE_BUCKET: env.TF_STATE_BUCKET,
    TF_STATE_REGION: env.TF_STATE_REGION,
    TF_STATE_ACCESS_KEY: env.TF_STATE_ACCESS_KEY,
    TF_STATE_SECRET_KEY: env.TF_STATE_SECRET_KEY
  }' >"${payload_file}"
  vault kv put -mount=kv "${secret_path}" "@${payload_file}" >/dev/null
  rm -f "${payload_file}"
  trap - EXIT
fi

record="$(vault kv get -mount=kv -format=json "${secret_path}")" || {
  echo "Vault KV path ${secret_path} is missing; run with SHARED_IAC_STATE_ACTION=write." >&2
  exit 1
}
for field in "${required_fields[@]}"; do
  jq -e --arg field "${field}" '.data.data[$field] | type == "string" and length > 0' \
    <<<"${record}" >/dev/null || {
    echo "${secret_path} is missing a non-empty ${field}" >&2
    exit 1
  }
done

echo "${secret_path}: all shared Terraform backend fields are present"
