#!/usr/bin/env bash
set -Eeuo pipefail

# Initialize the Akamai Cloud/Linode provider KV and the shared S3-compatible
# Terraform state KV. The canonical provider/OIDC implementation remains in
# scripts/vault; this file is only the documented, single entry point.
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"

usage() {
  cat <<'EOF'
Usage:
  docs/akamai-cloud/init-vault-kv.sh [--check|--apply] [--env uat|prod|all]

Required environment variables:
  VAULT_ADDR       Vault address, for example https://vault.svc.plus
  VAULT_TOKEN      Vault token with permission to write the target KV paths
  LINODE_TOKEN     Akamai Cloud/Linode API token
  AKAMAI_ACCOUNT_UAT   Concrete UAT account name or ID
  AKAMAI_ACCOUNT_PROD  Concrete PROD account name or ID

State variables may be shared by both environments:
  TF_STATE_ENDPOINT
  TF_STATE_BUCKET
  TF_STATE_ACCESS_KEY
  TF_STATE_SECRET_KEY
  TF_STATE_REGION

Or supplied per environment, for example:
  TF_STATE_ENDPOINT_UAT and TF_STATE_ENDPOINT_PROD

Optional:
  VAULT_MOUNT      KV v2 mount name (default: kv)
  ENV              Default environment (default: all)

Examples:
  export VAULT_ADDR='https://vault.svc.plus'
  export VAULT_TOKEN='hvs.***'
  export LINODE_TOKEN='***'
  export AKAMAI_ACCOUNT_UAT='actual-account'
  export AKAMAI_ACCOUNT_PROD='actual-account'
  export TF_STATE_ENDPOINT='https://s3.example.com'
  export TF_STATE_BUCKET='terraform-state'
  export TF_STATE_ACCESS_KEY='***'
  export TF_STATE_SECRET_KEY='***'
  export TF_STATE_REGION='us-east-1'
  docs/akamai-cloud/init-vault-kv.sh --apply --env all
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
  *) echo "invalid environment: ${target_env}" >&2; exit 2 ;;
esac

command -v vault >/dev/null 2>&1 || { echo "vault CLI is required" >&2; exit 1; }
export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_MOUNT="${VAULT_MOUNT:-kv}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be provided through the environment}"
: "${LINODE_TOKEN:?LINODE_TOKEN must be provided through the environment}"

account_for_env() {
  local env_name="$1"
  local account_var="AKAMAI_ACCOUNT_${env_name^^}"
  local account
  account="$(printenv "$account_var" 2>/dev/null || true)"
  : "${account:?set ${account_var} to a concrete account name or ID}"
  [[ "$account" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "invalid Akamai account: ${account}" >&2
    exit 2
  }
  case "$account" in
    primary|default|main)
      echo "account must be concrete, not alias: ${account}" >&2
      exit 2
      ;;
  esac
  printf '%s' "$account"
}

state_value() {
  local field="$1"
  local env_name="$2"
  local env_value
  env_value="$(printenv "${field}_${env_name^^}" 2>/dev/null || true)"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    return
  fi
  printenv "$field" 2>/dev/null || true
}

write_state_kv() {
  local env_name="$1"
  local path="CICD/${env_name}/iac_state"
  local endpoint bucket access_key secret_key region
  endpoint="$(state_value TF_STATE_ENDPOINT "$env_name")"
  bucket="$(state_value TF_STATE_BUCKET "$env_name")"
  access_key="$(state_value TF_STATE_ACCESS_KEY "$env_name")"
  secret_key="$(state_value TF_STATE_SECRET_KEY "$env_name")"
  region="$(state_value TF_STATE_REGION "$env_name")"

  for value_name in endpoint bucket access_key secret_key region; do
    [[ -n "${!value_name}" ]] || {
      echo "missing state value ${value_name} for ${env_name}" >&2
      exit 2
    }
  done

  if [[ "$mode" == check ]]; then
    for field in TF_STATE_ENDPOINT TF_STATE_BUCKET TF_STATE_ACCESS_KEY TF_STATE_SECRET_KEY TF_STATE_REGION; do
      vault kv get -mount="$VAULT_MOUNT" -field="$field" "$path" >/dev/null
    done
    echo "present kv/${path}"
    return
  fi

  printf '%s\n' "$endpoint" |
    vault kv put -mount="$VAULT_MOUNT" "$path" TF_STATE_ENDPOINT=- >/dev/null
  printf '%s\n' "$bucket" |
    vault kv patch -mount="$VAULT_MOUNT" "$path" TF_STATE_BUCKET=- >/dev/null
  printf '%s\n' "$access_key" |
    vault kv patch -mount="$VAULT_MOUNT" "$path" TF_STATE_ACCESS_KEY=- >/dev/null
  printf '%s\n' "$secret_key" |
    vault kv patch -mount="$VAULT_MOUNT" "$path" TF_STATE_SECRET_KEY=- >/dev/null
  printf '%s\n' "$region" |
    vault kv patch -mount="$VAULT_MOUNT" "$path" TF_STATE_REGION=- >/dev/null
  echo "written kv/${path}"
}

environments=(uat prod)
if [[ "$target_env" != all ]]; then
  environments=("$target_env")
fi

for env_name in "${environments[@]}"; do
  write_state_kv "$env_name"
done

if [[ "$mode" == apply ]]; then
  bash "${REPO_ROOT}/scripts/vault/bootstrap_akamai_oidc_roles.sh" --apply --env "$target_env"
  bash "${REPO_ROOT}/scripts/vault/bootstrap_akamai_cloud_kv.sh" --apply --env "$target_env"
else
  bash "${REPO_ROOT}/scripts/vault/bootstrap_akamai_oidc_roles.sh" --check --env "$target_env"
  bash "${REPO_ROOT}/scripts/vault/bootstrap_akamai_cloud_kv.sh" --check --env "$target_env"
fi

echo "Akamai Cloud/Linode Vault KV initialization ${mode} completed."
