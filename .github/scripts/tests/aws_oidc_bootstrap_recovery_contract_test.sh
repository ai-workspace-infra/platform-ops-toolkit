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
  'allow_root_break_glass' \
  'ALLOW_ROOT_BREAK_GLASS' \
  'Checkout AWS IaC identity module' \
  'Load Terraform state credentials' \
  'kv/data/CICD/prod/iac_state' \
  'Configure AWS credentials through the new GitHub OIDC role' \
  'Adopt GitHub OIDC resources into Terraform state' \
  'reconcile_github_oidc_trust.sh'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "AWS OIDC bootstrap workflow missing contract: ${required}" >&2
    exit 1
  }
done

for required in \
  'BOOTSTRAP_ACTION must be plan or apply' \
  'aws iam create-open-id-connect-provider' \
  'aws iam add-client-id-to-open-id-connect-provider' \
  'aws iam update-open-id-connect-provider-thumbprint' \
  'aws iam get-open-id-connect-provider' \
  'aws iam create-role' \
  'aws iam list-attached-role-policies' \
  'aws iam attach-role-policy' \
  'aws iam tag-role' \
  'arn:aws:iam::aws:policy/AdministratorAccess' \
  'aws iam update-assume-role-policy' \
  'AWS bootstrap workflow API scope:' \
  'root-principal break-glass session' \
  'allow_root_break_glass=true' \
  'Plan: would create OIDC provider' \
  'Plan: would create ${role_name}' \
  'GITHUB_OUTPUT' \
  'if [ "${action}" = "plan" ]' \
  'refs/tags/v*' \
  'environment:production'; do
  grep -Fq -- "${required}" "${script}" || {
    echo "AWS OIDC bootstrap script missing safety contract: ${required}" >&2
    exit 1
  }
done

test -x "${repo_root}/.github/scripts/aws/adopt_github_oidc_terraform_state.sh" || {
  echo "Terraform state-adoption script must be executable" >&2
  exit 1
}

for required in \
  'platform-ops-toolkit/prod/aws-cloud/bootstrap/identity/terraform.tfstate' \
  'aws_iam_openid_connect_provider.github_actions' \
  'aws_iam_role.github_actions_deploy_role' \
  'aws_iam_role_policy_attachment.github_actions_deploy_role_admin' \
  'import -input=false' \
  '-detailed-exitcode' \
  'Terraform state adoption found drift'; do
  grep -Fq -- "${required}" "${repo_root}/.github/scripts/aws/adopt_github_oidc_terraform_state.sh" || {
    echo "Terraform state-adoption script missing contract: ${required}" >&2
    exit 1
  }
done

for forbidden in 'terraform apply' 'terraform destroy'; do
  if grep -Fq -- "${forbidden}" "${repo_root}/.github/scripts/aws/adopt_github_oidc_terraform_state.sh"; then
    echo "Terraform state adoption must not run: ${forbidden}" >&2
    exit 1
  fi
done

for forbidden in \
  'aws iam create-policy' \
  'aws iam put-role-policy' \
  'aws s3 '; do
  if grep -Fq -- "${forbidden}" "${script}"; then
    echo "AWS OIDC bootstrap scope must not include: ${forbidden}" >&2
    exit 1
  fi
done

bash -n "${vault_roles}" || {
  echo "Vault bootstrap role provisioning script must have valid shell syntax" >&2
  exit 1
}

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
  'kv/data/CICD/prod/iac_state' \
  'aws-oidc-bootstrap.yml@*' \
  '"ref": "refs/heads/main"' \
  '"token_ttl": "20m"'; do
  grep -Fq -- "${required}" "${vault_roles}" || {
    echo "Vault bootstrap role provisioning is missing contract: ${required}" >&2
    exit 1
  }
done

echo "aws_oidc_bootstrap_recovery_contract_test: PASS"
