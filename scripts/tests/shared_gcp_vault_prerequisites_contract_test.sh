#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
roles_script="${repo_root}/scripts/vault/bootstrap_shared_gcp_roles.sh"
bootstrap_script="${repo_root}/scripts/gcp/bootstrap_gcp_auth_kv.sh"
state_script="${repo_root}/scripts/gcp/bootstrap_shared_iac_state_kv.sh"
workflow="${repo_root}/.github/workflows/gcp-oidc-bootstrap.yml"
policy="${repo_root}/scripts/vault/policies/github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod.hcl"
howto="${repo_root}/docs/howto/Vault-Shared-GCP-OIDC-Setup.md"

for file in "${roles_script}" "${bootstrap_script}" "${state_script}" "${workflow}" "${policy}" "${howto}"; do
  test -f "${file}" || { echo "missing shared Vault prerequisite declaration: ${file}" >&2; exit 1; }
done
for script in "${roles_script}" "${bootstrap_script}" "${state_script}"; do
  test -x "${script}" || { echo "script must be executable: ${script}" >&2; exit 1; }
  bash -n "${script}"
done

jq -e '
  .role_name == "github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod" and
  .bound_claims.environment == "prod" and
  .bound_claims.repository == "ai-workspace-infra/platform-ops-toolkit" and
  .bound_claims.ref == "refs/heads/main"
' "${repo_root}/scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod.json" >/dev/null
jq -e '
  .role_name == "github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod" and
  .bound_claims.environment == "prod" and
  .bound_claims.repository == "ai-workspace-infra/platform-ops-toolkit" and
  .bound_claims.ref == "refs/heads/main"
' "${repo_root}/scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod.json" >/dev/null

grep -Fq 'capabilities = ["read", "create", "update"]' "${policy}"
grep -Fq 'capabilities = ["read", "delete"]' "${policy}"
grep -Fq 'kv/data/CICD/shared/gcp-bootstrap/open-platform-prod' "${policy}"
grep -Fq 'kv/data/CICD/shared/iac_state' "${policy}"
grep -Fq 'kv/data/shared/platform/oidc/open-platform-prod' "${policy}"

for field in TF_STATE_ENDPOINT TF_STATE_BUCKET TF_STATE_REGION TF_STATE_ACCESS_KEY TF_STATE_SECRET_KEY; do
  grep -Fq "${field}" "${state_script}"
done
grep -Fq 'secret_path="CICD/shared/iac_state"' "${state_script}"
grep -Fq 'GCP_ENVIRONMENT must be uat, prod, or shared' "${bootstrap_script}"
grep -Fq 'GCP_ACCOUNT_ID=open-platform-prod' "${howto}"
grep -Fq 'GCP_PROJECT_ID=open-platform-prod' "${howto}"
grep -Fq 'GCP_ACCESS_TOKEN' "${howto}"
grep -Fq 'TF_STATE_SECRET_KEY' "${howto}"
grep -Fq 'Revoke and scrub short-lived GCP bootstrap access token' "${workflow}"

if grep -Fq 'roles/owner' "${bootstrap_script}"; then
  echo "shared bootstrap helper must not grant project Owner" >&2
  exit 1
fi

echo "shared_gcp_vault_prerequisites_contract_test: PASS"
