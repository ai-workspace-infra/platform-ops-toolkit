#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/gcp-oidc-bootstrap.yml"
resolver="${repo_root}/.github/scripts/gcp/resolve_github_oidc_config.sh"
runtime_action="${repo_root}/.github/actions/configure-gcp-oidc/action.yml"
landingzone_workflow="${repo_root}/.github/workflows/iac-pipeline-multi-cloud-landingzone-baseline.yaml"
account_workflow="${repo_root}/.github/workflows/iac-pipeline-multi-cloud-account-matrix.yaml"
resources_workflow="${repo_root}/.github/workflows/iac-pipeline-multi-cloud-resources-matrix.yaml"
master_workflow="${repo_root}/.github/workflows/iac-pipeline-multi-cloud-master.yaml"
gcp_iac_workflow="${repo_root}/.github/workflows/gcp-iac-pipeline.yml"
vault_roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"
vault_role_dir="${repo_root}/scripts/vault/roles"
vault_policy_dir="${repo_root}/scripts/vault/policies"
kv_helper="${repo_root}/scripts/gcp/bootstrap_gcp_auth_kv.sh"

test -x "${resolver}" || { echo "GCP OIDC resolver must be executable" >&2; exit 1; }
test -x "${kv_helper}" || { echo "GCP Vault KV helper must be executable" >&2; exit 1; }
test -f "${gcp_iac_workflow}" || { echo "GCP IAC workflow must exist" >&2; exit 1; }

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
  'Verify GCP project bootstrap permissions' \
  'testIamPermissions' \
  'iam.serviceAccounts.create' \
  'iam.serviceAccounts.setIamPolicy' \
  'serviceusage.services.enable' \
  'kv/data/CICD/${{ inputs.environment }}/iac_state TF_STATE_ENDPOINT | TF_STATE_ENDPOINT' \
  'kv/data/CICD/${{ inputs.environment }}/iac_state TF_STATE_BUCKET | TF_STATE_BUCKET' \
  'kv/data/CICD/${{ inputs.environment }}/iac_state TF_STATE_ACCESS_KEY | TF_STATE_ACCESS_KEY' \
  'kv/data/CICD/${{ inputs.environment }}/iac_state TF_STATE_SECRET_KEY | TF_STATE_SECRET_KEY' \
  'kv/data/CICD/${{ inputs.environment }}/iac_state TF_STATE_REGION | TF_STATE_REGION' \
  'backend-config="endpoint=${TF_STATE_ENDPOINT}"' \
  'backend-config="key=${{ steps.config.outputs.state_key }}"' \
  'backend-config="use_path_style=true"' \
  'identity plan' \
  'identity apply' \
  'if: ${{ inputs.action == '\''apply'\'' }}' \
  'google-github-actions/auth@v2' \
  'gcloud projects describe' \
  'Verify UAT cannot access PROD' \
  'xwork-open-platform-prod' \
  'allowed_subjects' \
  'gcp_oidc_audience' \
  'WIF pool/provider create permissions will be validated by the Terraform IAM API operation.' \
  'kv/data/${ENVIRONMENT}/platform/oidc/${ACCOUNT_ID}'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "GCP OIDC bootstrap workflow missing contract: ${required}" >&2
    exit 1
  }
done

for required in \
  'options: [plan, apply, destroy]' \
  'options: [uat, prod]' \
  'gcp_account_id:' \
  'gcp_resource_manifest:' \
  'iac_ref:' \
  'environment:' \
  'uses: ./.github/actions/configure-gcp-oidc' \
  'scripts/generate.py render' \
  'envs/${DEPLOY_ENV}' \
  'backend-config="key=terraform/${{ env.DEPLOY_ENV }}/${{ steps.config.outputs.project_id }}/gcp-cloud/${{ env.GCP_ACCOUNT_ID }}/platform/terraform.tfstate"' \
  'Terraform apply' \
  'Terraform destroy'; do
  grep -Fq -- "${required}" "${gcp_iac_workflow}" || {
    echo "GCP IAC workflow missing parameterized runtime contract: ${required}" >&2
    exit 1
  }
done

for required in \
  'spot_vms' \
  'spot_instance_name' \
  'gcloud compute instances describe' \
  'scheduling.provisioningModel' \
  'Expected ${INSTANCE_NAME} to be SPOT'; do
  grep -Fq -- "${required}" "${gcp_iac_workflow}" || {
    echo "GCP IAC workflow missing Spot verification contract: ${required}" >&2
    exit 1
  }
done

grep -Fq 'kv/data/CICD/${{ inputs.environment }}/iac_state TF_STATE_ENDPOINT | TF_STATE_ENDPOINT' "${runtime_action}" || {
  echo "GCP runtime OIDC action must load the shared state contract" >&2
  exit 1
}
grep -Fq 'state_endpoint:' "${runtime_action}" || {
  echo "GCP runtime OIDC action must expose state backend outputs" >&2
  exit 1
}

grep -Fq "if: \${{ inputs.cloud_provider == 'gcp-cloud' }}" "${master_workflow}" || {
  echo "Multi-cloud master must route gcp-cloud to the GCP IAC workflow" >&2
  exit 1
}
grep -Fq 'uses: ./.github/workflows/gcp-iac-pipeline.yml' "${master_workflow}" || {
  echo "Multi-cloud master missing GCP IAC workflow route" >&2
  exit 1
}

for required in \
  'method: jwt' \
  'github-actions-platform-ops-toolkit-${{ inputs.environment }}-gcp-oidc-${{ inputs.account_id }}' \
  'kv/data/${{ inputs.environment }}/platform/oidc/${{ inputs.account_id }}' \
  'google-github-actions/auth@v2' \
  'Google STS'; do
  grep -Fq -- "${required}" "${runtime_action}" || {
    echo "GCP runtime OIDC action missing contract: ${required}" >&2
    exit 1
  }
done

for multi_cloud_workflow in "${landingzone_workflow}" "${account_workflow}" "${resources_workflow}"; do
  for required in 'gcp_account_id:' 'configure-gcp-oidc' "if: env.CLOUD_PROVIDER == 'gcp-cloud'"; do
    grep -Fq -- "${required}" "${multi_cloud_workflow}" || {
      echo "GCP multi-cloud workflow missing contract (${required}): ${multi_cloud_workflow}" >&2
      exit 1
    }
  done
  if grep -Fq 'arn:aws:iam::' "${multi_cloud_workflow}"; then
    echo "GCP-capable multi-cloud workflow must not hard-code an AWS role: ${multi_cloud_workflow}" >&2
    exit 1
  fi
done

for required in 'gcp_account_id:' 'gcp_account_id: ${{ inputs.gcp_account_id'; do
  grep -Fq -- "${required}" "${master_workflow}" || {
    echo "Multi-cloud master missing GCP account input forwarding: ${required}" >&2
    exit 1
  }
done

for env in uat prod; do
  runtime_role="${vault_role_dir}/github-actions-platform-ops-toolkit-${env}-gcp-oidc-xworktech.json"
  runtime_policy="${vault_policy_dir}/github-actions-platform-ops-toolkit-${env}-gcp-oidc-xworktech.hcl"
  test -f "${runtime_role}" || { echo "missing GCP runtime role declaration: ${runtime_role}" >&2; exit 1; }
  test -f "${runtime_policy}" || { echo "missing GCP runtime policy declaration: ${runtime_policy}" >&2; exit 1; }
  jq -e --arg env "${env}" --arg role "github-actions-platform-ops-toolkit-${env}-gcp-oidc-xworktech" '
    .role_name == $role and
    .bound_claims.repository == "ai-workspace-infra/platform-ops-toolkit" and
    (.bound_claims.job_workflow_ref | tostring | contains("iac-pipeline-multi-cloud")) and
    (.token_policies | index($role) != null) and
    .token_ttl == "20m" and .token_max_ttl == "20m"
  ' "${runtime_role}" >/dev/null || {
    echo "invalid GCP runtime role declaration: ${runtime_role}" >&2
    exit 1
  }
  grep -Fq 'capabilities = ["read"]' "${runtime_policy}"
  grep -Fq "kv/data/${env}/platform/oidc/xworktech" "${runtime_policy}"
  opposite_env=$([[ "${env}" == uat ]] && echo prod || echo uat)
  if grep -Eq "kv/(data|metadata)/${opposite_env}/" "${runtime_policy}"; then
    echo "GCP runtime policy crosses environments: ${runtime_policy}" >&2
    exit 1
  fi
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
  'GCP_PROJECT_ID does not match GCP_ENVIRONMENT' \
  'GCP_EXPECTED_PROJECT_ID is required for non-xworktech accounts'; do
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
  'xwork-open-platform-uat' \
  'xwork-open-platform-prod' \
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
