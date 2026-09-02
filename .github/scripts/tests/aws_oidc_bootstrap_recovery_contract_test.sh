#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/aws-oidc-bootstrap.yml"
script="${repo_root}/.github/scripts/aws/reconcile_github_oidc_trust.sh"
vault_roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"

test -x "${script}" || {
  echo "AWS OIDC bootstrap reconciliation script must be executable" >&2
  exit 1
}

for required in \
  'github-actions-platform-ops-toolkit-prod-aws-bootstrap' \
  'kv/data/CICD/prod/aws-bootstrap' \
  'environment: production' \
  'options: [plan, apply]' \
  'reconcile_github_oidc_trust.sh'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "AWS OIDC bootstrap workflow missing contract: ${required}" >&2
    exit 1
  }
done

for required in \
  'BOOTSTRAP_ACTION must be plan or apply' \
  'aws iam get-open-id-connect-provider' \
  'aws iam update-assume-role-policy' \
  'if [ "${action}" = "plan" ]' \
  'refs/tags/v*'; do
  grep -Fq -- "${required}" "${script}" || {
    echo "AWS OIDC bootstrap script missing safety contract: ${required}" >&2
    exit 1
  }
done

if grep -Fq 'AWS_ROOT_ACCESS_KEY' "${workflow}" "${script}"; then
  echo "AWS OIDC bootstrap must not use root access-key fields" >&2
  exit 1
fi

for required in \
  'outputToken: true' \
  'Load optional AWS session token' \
  'AWS_SESSION_TOKEN // empty' \
  'AWS_SESSION_TOKEN=%s' \
  'steps.vault.outputs.vault_token'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "AWS OIDC bootstrap optional session-token contract missing: ${required}" >&2
    exit 1
  }
done

for required in \
  'write_aws_oidc_bootstrap_policy' \
  'write_aws_oidc_bootstrap_role' \
  'kv/data/CICD/prod/aws-bootstrap' \
  'aws-oidc-bootstrap.yml@*' \
  '"ref": "refs/heads/main"' \
  '"token_ttl": "20m"'; do
  grep -Fq -- "${required}" "${vault_roles}" || {
    echo "Vault bootstrap role provisioning is missing contract: ${required}" >&2
    exit 1
  }
done

echo "aws_oidc_bootstrap_recovery_contract_test: PASS"
