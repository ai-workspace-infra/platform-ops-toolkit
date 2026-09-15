#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/gcp-oidc-bootstrap.yml"
resolver="${repo_root}/.github/scripts/gcp/resolve_github_oidc_config.sh"
vault_roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"
vault_role_dir="${repo_root}/scripts/vault/roles"
vault_policy_dir="${repo_root}/scripts/vault/policies"
kv_helper="${repo_root}/scripts/gcp/bootstrap_gcp_auth_kv.sh"

test -x "${resolver}" || { echo "GCP OIDC resolver must be executable" >&2; exit 1; }
test -x "${kv_helper}" || { echo "GCP Vault KV helper must be executable" >&2; exit 1; }

for required in \
  'environment:' \
  'options: [uat, prod]' \
  'action:' \
  'options: [plan, apply]' \
  'id-token: write' \
  'name: ${{ inputs.environment }}' \
  'Checkout GitOps GCP OIDC declaration' \
  'resources/xworktech.com/${{ inputs.environment }}/gcp/github-actions-oidc.yaml' \
  'hashicorp/vault-action' \
  'github-actions-platform-ops-toolkit-${{ inputs.environment }}-gcp-bootstrap-${{ steps.config.outputs.account_id }}' \
  'kv/data/CICD/${{ inputs.environment }}/gcp-bootstrap/${{ steps.config.outputs.account_id }}' \
  'kv/data/CICD TF_STATE_ENDPOINT | TF_STATE_ENDPOINT' \
  'kv/data/CICD TF_STATE_BUCKET | TF_STATE_BUCKET' \
  'kv/data/CICD TF_STATE_ACCESS_KEY | TF_STATE_ACCESS_KEY' \
  'kv/data/CICD TF_STATE_SECRET_KEY | TF_STATE_SECRET_KEY' \
  'kv/data/CICD TF_STATE_REGION | TF_STATE_REGION' \
  'backend-config="endpoint=${TF_STATE_ENDPOINT}"' \
  'backend-config="key=${{ steps.config.outputs.state_key }}"' \
  'backend-config="use_path_style=true"' \
  'identity plan' \
  'identity apply' \
  'if: ${{ inputs.action == '\''apply'\'' }}' \
  'google-github-actions/auth@v2' \
  'gcloud projects describe' \
  'Verify UAT cannot access PROD' \
  'xworktech-open-platform-prod' \
  'kv/data/${ENVIRONMENT}/platform/oidc/${ACCOUNT_ID}'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "GCP OIDC bootstrap workflow missing contract: ${required}" >&2
    exit 1
  }
done

for forbidden in 'backend "gcs"' 'backend-config="prefix=' 'state_bucket }}'; do
  if grep -Fq -- "${forbidden}" "${workflow}"; then
    echo "GCP OIDC bootstrap must use the shared S3-compatible state backend: ${forbidden}" >&2
    exit 1
  fi
done

for required in \
  'GCP_ACCOUNT_ID is required' \
  'CICD/${environment}/gcp-bootstrap/${account_id}' \
  'GCP_BOOTSTRAP_ACTION must be write or check' \
  'gcloud auth application-default print-access-token' \
  'GCP_PROJECT_ID does not match GCP_ENVIRONMENT'; do
  grep -Fq -- "${required}" "${kv_helper}" || {
    echo "GCP Vault KV helper missing contract: ${required}" >&2
    exit 1
  }
done

for forbidden in 'credentials.json' 'service_account_key'; do
  if grep -Fqi -- "${forbidden}" "${workflow}" "${resolver}"; then
    echo "GCP OIDC bootstrap must not use long-lived credentials: ${forbidden}" >&2
    exit 1
  fi
done

for required in \
  'GCP_ENVIRONMENT must be uat or prod' \
  'https://token.actions.githubusercontent.com' \
  'https://iam.googleapis.com/' \
  '744119519286' \
  'xworktech-open-platform-uat' \
  'xworktech-open-platform-prod' \
  'spec.subjects' \
  'platform-ops-toolkit/#{environment}/#{account_id}/gcp-oidc-bootstrap/terraform.tfstate'; do
  grep -Fq -- "${required}" "${resolver}" || {
    echo "GCP OIDC resolver missing validation: ${required}" >&2
    exit 1
  }
done

for required in 'scripts/vault/policies' 'scripts/vault/roles' 'vault policy write' 'auth/jwt/role/'; do
  grep -Fq -- "${required}" "${vault_roles}" || {
    echo "Vault role orchestration contract missing: ${required}" >&2
    exit 1
  }
done

for env in uat prod; do
  role_file="${vault_role_dir}/github-actions-platform-ops-toolkit-${env}-gcp-bootstrap-xworktech.json"
  policy_file="${vault_policy_dir}/github-actions-platform-ops-toolkit-${env}-gcp-bootstrap-xworktech.hcl"
  test -f "${role_file}" || { echo "missing GCP role declaration: ${role_file}" >&2; exit 1; }
  test -f "${policy_file}" || { echo "missing GCP policy declaration: ${policy_file}" >&2; exit 1; }
  jq -e --arg env "${env}" '
    .role_name == ("github-actions-platform-ops-toolkit-" + $env + "-gcp-bootstrap-xworktech") and
    .bound_claims.environment == $env and
    .bound_claims.repository == "ai-workspace-infra/platform-ops-toolkit" and
    .bound_claims.ref == "refs/heads/main" and
    (.bound_claims.job_workflow_ref | tostring | contains("gcp-oidc-bootstrap.yml")) and
    .token_ttl == "20m" and .token_max_ttl == "20m"
  ' "${role_file}" >/dev/null || {
    echo "invalid GCP role declaration: ${role_file}" >&2
    exit 1
  }
  grep -Fq 'path "kv/data/CICD"' "${policy_file}"
  grep -Fq "kv/data/CICD/${env}/gcp-bootstrap/xworktech" "${policy_file}"
  grep -Fq "kv/data/${env}/platform/oidc/xworktech" "${policy_file}"
  opposite_env=$([[ "${env}" == uat ]] && echo prod || echo uat)
  if grep -Eq "kv/(data|metadata)/${opposite_env}/" "${policy_file}"; then
    echo "GCP policy crosses environments: ${policy_file}" >&2
    exit 1
  fi
done

if grep -Eiq 'vault[[:space:]]+delete.*gcp-bootstrap' "${vault_roles}"; then
  echo "GCP bootstrap roles must not be deleted by the orchestrator" >&2
  exit 1
fi

for cloud_role in \
  'github-actions-platform-ops-toolkit-prod-aws-bootstrap' \
  'github-actions-platform-ops-toolkit-uat-gcp-bootstrap-xworktech' \
  'github-actions-platform-ops-toolkit-prod-gcp-bootstrap-xworktech'; do
  if grep -Eiq "vault[[:space:]]+delete.*${cloud_role}" "${vault_roles}"; then
    echo "cloud bootstrap role must not be deleted by the orchestrator: ${cloud_role}" >&2
    exit 1
  fi
done

bash -n "${resolver}"
bash -n "${vault_roles}"
bash -n "${kv_helper}"
echo "gcp_oidc_bootstrap_contract_test: PASS"
