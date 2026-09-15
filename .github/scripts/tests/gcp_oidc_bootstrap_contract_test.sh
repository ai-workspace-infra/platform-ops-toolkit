#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/gcp-oidc-bootstrap.yml"
resolver="${repo_root}/.github/scripts/gcp/resolve_github_oidc_config.sh"
vault_roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"

test -x "${resolver}" || { echo "GCP OIDC resolver must be executable" >&2; exit 1; }

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
  'github-actions-platform-ops-toolkit-${{ inputs.environment }}-gcp-bootstrap' \
  'kv/data/CICD/${{ inputs.environment }}/gcp-bootstrap' \
  'identity plan' \
  'identity apply' \
  'if: ${{ inputs.action == '\''apply'\'' }}' \
  'google-github-actions/auth@v2' \
  'gcloud projects describe' \
  'Verify UAT cannot access PROD' \
  'xworktech-open-platform-prod' \
  'kv/data/${ENVIRONMENT}/platform/oidc'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "GCP OIDC bootstrap workflow missing contract: ${required}" >&2
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
  'platform-ops-toolkit/#{environment}/gcp-oidc-bootstrap/terraform.tfstate'; do
  grep -Fq -- "${required}" "${resolver}" || {
    echo "GCP OIDC resolver missing validation: ${required}" >&2
    exit 1
  }
done

for required in \
  'github-actions-platform-ops-toolkit-${env}-gcp-bootstrap' \
  'kv/data/CICD/${env}/gcp-bootstrap' \
  'kv/data/${env}/platform/oidc' \
  'gcp-oidc-bootstrap.yml@*' \
  '"environment": "${env}"' \
  '"token_ttl": "20m"'; do
  grep -Fq -- "${required}" "${vault_roles}" || {
    echo "Vault GCP bootstrap contract missing: ${required}" >&2
    exit 1
  }
done

bash -n "${resolver}"
bash -n "${vault_roles}"
echo "gcp_oidc_bootstrap_contract_test: PASS"
