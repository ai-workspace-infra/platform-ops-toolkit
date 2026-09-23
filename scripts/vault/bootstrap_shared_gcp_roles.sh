#!/usr/bin/env bash
set -euo pipefail

# Reconcile only the shared open-platform-prod GCP bootstrap/runtime Vault roles.
# Default is read-only --check; use --apply to write these two roles/policies.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/../.." && pwd -P)"
role_dir="${repo_root}/scripts/vault/roles"
policy_dir="${repo_root}/scripts/vault/policies"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
mode=check

while (($#)); do
  case "$1" in
    --check) mode=check ;;
    --apply) mode=apply ;;
    -h|--help)
      printf 'Usage: %s [--check|--apply]\n' "$0"
      printf 'Targets only shared open-platform-prod GCP bootstrap/runtime JWT roles and policies.\n'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

export VAULT_ADDR="${vault_addr}"
for command_name in vault jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required" >&2
    exit 1
  }
done
if [[ -z "${VAULT_TOKEN:-}" ]] && ! vault token lookup >/dev/null 2>&1; then
  echo "Vault authentication is required; use an authorized admin CLI session or VAULT_TOKEN." >&2
  exit 1
fi

names=(
  github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod
  github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod
)

for name in "${names[@]}"; do
  role_file="${role_dir}/${name}.json"
  policy_file="${policy_dir}/${name}.hcl"
  test -f "${role_file}" && test -f "${policy_file}" || {
    echo "Missing shared Vault declaration for ${name}" >&2
    exit 1
  }
  if [[ "${name}" == *-bootstrap-* ]]; then
    workflow_claim=workflow_ref
    workflow_value="ai-workspace-infra/platform-ops-toolkit/.github/workflows/gcp-oidc-bootstrap.yml@refs/heads/main"
  else
    workflow_claim=job_workflow_ref
    workflow_value="ai-workspace-infra/platform-ops-toolkit/.github/workflows/gcp-iac-pipeline.yml@*"
  fi
  jq -e --arg name "${name}" --arg workflow_claim "${workflow_claim}" --arg workflow_value "${workflow_value}" '
    .role_name == $name and
    .role_type == "jwt" and
    .user_claim == "sub" and
    .token_no_default_policy == true and
    .token_type == "batch" and
    (.bound_claims.repository == "ai-workspace-infra/platform-ops-toolkit") and
    (.bound_claims.environment == "prod") and
    (.bound_claims.ref == "refs/heads/main") and
    (.bound_claims[$workflow_claim] == $workflow_value) and
    (.token_policies | length == 1 and .[0] == $name)
  ' "${role_file}" >/dev/null || {
    echo "Invalid or unexpectedly broad shared role declaration: ${role_file}" >&2
    exit 1
  }

  if [[ "${mode}" == apply ]]; then
    echo "Writing shared GCP policy ${name}..."
    vault policy write "${name}" "${policy_file}" >/dev/null
    echo "Writing shared GCP JWT role ${name}..."
    jq -c 'del(.role_name, .description)' "${role_file}" |
      vault write "auth/jwt/role/${name}" - >/dev/null
  else
    vault policy read "${name}" >/dev/null
    vault read "auth/jwt/role/${name}" >/dev/null
    echo "${name}: present"
  fi
done

echo "Shared GCP Vault role/policy ${mode}: OK"
