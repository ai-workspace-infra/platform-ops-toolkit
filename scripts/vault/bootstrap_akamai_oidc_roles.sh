#!/usr/bin/env bash
set -Eeuo pipefail

# Render and publish the environment/account-specific Vault JWT roles and
# policies required by the Akamai Cloud/Linode GitHub Actions workflow.
# Account names are inputs; no account alias or secret is embedded here.
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

usage() {
  cat <<'EOF'
Usage:
  bootstrap_akamai_oidc_roles.sh [--check|--apply] [--env uat|prod|all]

Required environment variables:
  VAULT_ADDR            Vault address, for example https://vault.svc.plus
  VAULT_TOKEN           Vault admin/policy-management token
  AKAMAI_ACCOUNT_UAT    Concrete UAT Akamai account name or ID
  AKAMAI_ACCOUNT_PROD   Concrete PROD Akamai account name or ID

Optional environment variables:
  VAULT_JWT_AUTH_MOUNT  JWT auth mount (default: auth/jwt)
  ENV                   Default target environment (default: all)

Examples:
  export VAULT_ADDR=https://vault.svc.plus
  export VAULT_TOKEN='...'
  export AKAMAI_ACCOUNT_UAT='actual-uat-account'
  export AKAMAI_ACCOUNT_PROD='actual-prod-account'
  bash scripts/vault/bootstrap_akamai_oidc_roles.sh --apply --env all

Use --check to verify the generated policy and role already exist.
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
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be provided through the environment}"
VAULT_JWT_AUTH_MOUNT="${VAULT_JWT_AUTH_MOUNT:-auth/jwt}"
VAULT_JWT_AUTH_MOUNT="${VAULT_JWT_AUTH_MOUNT#/}"
VAULT_JWT_AUTH_MOUNT="${VAULT_JWT_AUTH_MOUNT%/}"

account_for_env() {
  local env_name="$1"
  local account=""
  case "$env_name" in
    uat) account="${AKAMAI_ACCOUNT_UAT:-}" ;;
    prod) account="${AKAMAI_ACCOUNT_PROD:-}" ;;
  esac
  : "${account:?set AKAMAI_ACCOUNT_${env_name^^} to a concrete account name or ID}"
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

publish_env() {
  local env_name="$1"
  local account="$2"
  local policy_name="github-actions-platform-ops-toolkit-${env_name}-akamai-oidc-bootstrap-${account}"
  local role_name="$policy_name"
  local policy_file role_file
  policy_file="${tmp_dir}/${env_name}-${account}.hcl"
  role_file="${tmp_dir}/${env_name}-${account}.json"

  sed -e "s/__ENV__/${env_name}/g" -e "s/__ACCOUNT__/${account}/g" \
    "${TEMPLATE_DIR}/akamai-oidc-policy.hcl.tmpl" >"${policy_file}"
  sed -e "s/__ACCOUNT__/${account}/g" \
    "${TEMPLATE_DIR}/akamai-oidc-role-${env_name}.json.tmpl" >"${role_file}"

  if [[ "$mode" == check ]]; then
    vault policy read "$policy_name" >/dev/null
    vault read "${VAULT_JWT_AUTH_MOUNT}/role/${role_name}" >/dev/null
    verify_role_claims "$env_name" "$account" "$role_name"
    echo "present ${env_name}/${account}"
    return
  fi

  vault policy write "$policy_name" "$policy_file" >/dev/null
  jq -c 'del(.role_name, .description)' "$role_file" |
    vault write "${VAULT_JWT_AUTH_MOUNT}/role/${role_name}" - >/dev/null
  verify_role_claims "$env_name" "$account" "$role_name"
  echo "written ${env_name}/${account}"
}

verify_role_claims() {
  local env_name="$1"
  local account="$2"
  local role_name="$3"
  local expected_environment="$env_name"
  local role_json

  role_json="$(vault read -format=json "${VAULT_JWT_AUTH_MOUNT}/role/${role_name}")"
  if ! jq -e \
    --arg repository "ai-workspace-infra/platform-ops-toolkit" \
    --arg iac_workflow "ai-workspace-infra/platform-ops-toolkit/.github/workflows/akamai-cloud-iac.yml@*" \
    --arg selfhost_workflow "ai-workspace-infra/platform-ops-toolkit/.github/workflows/selfhost-orchestrator.yml@*" \
    --arg preflight_workflow "ai-workspace-infra/platform-ops-toolkit/.github/workflows/akamai-uat-migration-preflight.yml@*" \
    --arg expected_ref "refs/heads/main" \
    --arg expected_environment "$expected_environment" '
      def as_array: if type == "array" then . else [.] end;
      .data.bound_claims as $claims
      | ($claims.job_workflow_ref | as_array) as $workflows
      | ($claims.ref | as_array) as $refs
      | (
          ($workflows | index($iac_workflow)) != null
          and ($workflows | index($selfhost_workflow)) != null
          and ($expected_environment != "uat" or ($workflows | index($preflight_workflow)) != null)
          and ($claims.repository == $repository)
          and (($refs | index($expected_ref)) != null)
          and ($claims.environment == $expected_environment)
        )
    ' <<<"$role_json" >/dev/null; then
    echo "::error::Vault role ${role_name} was written/read, but its repository/ref/environment/job_workflow_ref claims are not the Akamai Cloud contract for ${env_name}/${account}." >&2
    echo "::error::Required workflows: akamai-cloud-iac.yml and selfhost-orchestrator.yml; UAT also requires akamai-uat-migration-preflight.yml; required ref: refs/heads/main; required environment: ${expected_environment}." >&2
    return 1
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

environments=(uat prod)
if [[ "$target_env" != all ]]; then
  environments=("$target_env")
fi

for env_name in "${environments[@]}"; do
  publish_env "$env_name" "$(account_for_env "$env_name")"
done

echo "Akamai Cloud Vault OIDC role/policy ${mode} completed."
