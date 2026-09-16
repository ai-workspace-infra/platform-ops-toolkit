#!/usr/bin/env bash
set -Eeuo pipefail

# Write the Akamai Cloud/Linode provider token into the environment-specific
# Vault KV v2 records.  Secret values are read only from the environment and
# are never printed by this script.
umask 077

usage() {
  cat <<'EOF'
Usage:
  bootstrap_akamai_cloud_kv.sh [--check|--apply] [--env uat|prod|all]

Required environment variables:
  VAULT_ADDR       Vault address, for example https://vault.svc.plus
  VAULT_TOKEN      Vault token with permission to write the target KV paths
  LINODE_TOKEN     Akamai Cloud/Linode API token used by linode/linode
  AKAMAI_ACCOUNT_UAT   Concrete UAT Akamai account name or ID
  AKAMAI_ACCOUNT_PROD  Concrete PROD Akamai account name or ID

Optional environment variables:
  VAULT_MOUNT      KV v2 mount name (default: kv)
  ENV              Default target environment when --env is omitted (default: all)

Examples:
  export VAULT_ADDR=https://vault.svc.plus
  export VAULT_TOKEN='...'
  export LINODE_TOKEN='...'
  export AKAMAI_ACCOUNT_UAT='actual-uat-account'
  export AKAMAI_ACCOUNT_PROD='actual-prod-account'
  bash scripts/vault/bootstrap_akamai_cloud_kv.sh --apply --env all

Use --check to verify that the records and LINODE_TOKEN field already exist.
The values primary/default/main are rejected because account must be concrete.
EOF
}

mode=check
target_env="${ENV:-all}"

while (($# > 0)); do
  case "$1" in
    --check) mode=check ;;
    --apply) mode=apply ;;
    --env)
      (($# >= 2)) || { echo "--env requires uat, prod, or all" >&2; exit 2; }
      target_env="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

target_env="${target_env,,}"
case "$target_env" in
  uat|prod|all) ;;
  *) echo "invalid environment: $target_env" >&2; exit 2 ;;
esac

command -v vault >/dev/null 2>&1 || {
  echo "vault CLI is required" >&2
  exit 1
}

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_MOUNT="${VAULT_MOUNT:-kv}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be provided through the environment}"

: "${LINODE_TOKEN:?LINODE_TOKEN must be provided through the environment}"

account_for_env() {
  local env_name="$1"
  local account=""
  case "$env_name" in
    uat) account="${AKAMAI_ACCOUNT_UAT:-}" ;;
    prod) account="${AKAMAI_ACCOUNT_PROD:-}" ;;
  esac

  if [[ -z "$account" && "$target_env" != all ]]; then
    account="${AKAMAI_ACCOUNT:-}"
  fi
  : "${account:?set AKAMAI_ACCOUNT_${env_name^^} (or AKAMAI_ACCOUNT for a single environment)}"

  [[ "$account" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "Akamai account must contain only letters, numbers, dot, underscore, or hyphen: $account" >&2
    exit 2
  }
  case "$account" in
    primary|default|main)
      echo "Akamai account must be a concrete account name or ID, not alias: $account" >&2
      exit 2
      ;;
  esac
  printf '%s' "$account"
}

write_or_patch() {
  local env_name="$1"
  local account="$2"
  local path="CICD/${env_name}/akamai-cloud/${account}"

  if [[ "$mode" == check ]]; then
    vault kv get -mount="$VAULT_MOUNT" -field=LINODE_TOKEN "$path" >/dev/null
    echo "present kv/${path}"
    return
  fi

  if vault kv get -mount="$VAULT_MOUNT" "$path" >/dev/null 2>&1; then
    printf '%s\n' "$LINODE_TOKEN" |
      vault kv patch -mount="$VAULT_MOUNT" "$path" LINODE_TOKEN=- >/dev/null
  else
    printf '%s\n' "$LINODE_TOKEN" |
      vault kv put -mount="$VAULT_MOUNT" "$path" LINODE_TOKEN=- >/dev/null
  fi
  echo "written kv/${path}"
}

environments=(uat prod)
if [[ "$target_env" != all ]]; then
  environments=("$target_env")
fi

for env_name in "${environments[@]}"; do
  account="$(account_for_env "$env_name")"
  write_or_patch "$env_name" "$account"
done

if [[ "$mode" == check ]]; then
  echo "Akamai Cloud Vault KV check completed."
else
  echo "Akamai Cloud Vault Vault KV initialization completed."
fi
