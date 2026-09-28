#!/usr/bin/env bash
# Write or verify the optional Vultr provider credential in the established
# environment-level Vault record. State credentials remain in /iac_state.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage:
  bootstrap_vultr_auth_kv.sh --write --env sit|uat|prod
  bootstrap_vultr_auth_kv.sh --check --env sit|uat|prod

Required for --write:
  VULTR_API_KEY
  VAULT_ADDR (default: https://vault.svc.plus)
  VAULT_TOKEN, or an authenticated Vault CLI session

Record: kv/CICD/<env>, field: VULTR_API_KEY
Terraform state fields belong only to kv/CICD/<env>/iac_state.
EOF
}

action="${VULTR_BOOTSTRAP_ACTION:-check}"
environment="${VULTR_ENVIRONMENT:-${ENV:-}}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
vault_mount="${VAULT_MOUNT:-kv}"

while (($# > 0)); do
  case "$1" in
    --write|--apply) action=write ;;
    --check) action=check ;;
    --env)
      (($# >= 2)) || { echo "--env requires sit, uat or prod" >&2; exit 2; }
      environment="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "${action}" in write|check) ;; *) echo "VULTR_BOOTSTRAP_ACTION must be check or write" >&2; exit 2 ;; esac
case "${environment}" in sit|uat|prod) ;; *) echo "VULTR_ENVIRONMENT/ENV must be sit, uat or prod" >&2; exit 2 ;; esac
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || { echo "VAULT_ADDR must be an https:// or http:// Vault URL" >&2; exit 2; }
command -v vault >/dev/null 2>&1 || { echo "vault CLI is required" >&2; exit 1; }
export VAULT_ADDR="${vault_addr}"

secret_path="CICD/${environment}"
if [[ "${action}" == write ]]; then
  : "${VULTR_API_KEY:?VULTR_API_KEY is required for --write}"
  vault kv patch -mount="${vault_mount}" "${secret_path}" VULTR_API_KEY=- <<<"${VULTR_API_KEY}" >/dev/null
  unset VULTR_API_KEY
  echo "kv/${secret_path}: Vultr credential written"
else
  vault kv get -mount="${vault_mount}" -field=VULTR_API_KEY "${secret_path}" >/dev/null || {
    echo "kv/${secret_path} is missing VULTR_API_KEY" >&2
    exit 1
  }
  echo "kv/${secret_path}: OK"
fi
