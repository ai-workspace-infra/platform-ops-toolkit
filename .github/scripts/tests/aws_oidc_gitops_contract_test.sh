#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
resolver="${repo_root}/.github/scripts/gitops/resolve_gitops_aws_oidc_config.sh"

test -x "${resolver}" || {
  echo "AWS OIDC GitOps resolver must be executable" >&2
  exit 1
}

for required in \
  "resources/svc.plus/\${{ steps.route.outputs.deployment_env }}/aws/github-actions-oidc.json" \
  "Resolve AWS OIDC deployment configuration from GitOps" \
  "steps.aws_oidc.outputs.role_arn" \
  "steps.aws_oidc.outputs.region" \
  "steps.aws_oidc.outputs.audience" \
  "EXPECTED_CLOUD_ACCOUNT: \${{ steps.route.outputs.account }}"; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "Selfhost orchestrator is missing AWS OIDC GitOps contract: ${required}" >&2
    exit 1
  }
done

if grep -Fq 'arn:aws:iam::950604983695:role/GithubAction_IAC_Deploy_Role' "${workflow}"; then
  echo "Selfhost orchestrator must not hard-code the AWS deployment role" >&2
  exit 1
fi

for required in \
  'GitHubActionsOIDCConfig' \
  'https://token.actions.githubusercontent.com' \
  'sts.amazonaws.com' \
  'refs/heads/main' \
  'refs/tags/v*' \
  'refs/tags/uat-daily-build-*' \
  'environment:uat' \
  'environment:production' \
  'Unsupported AWS OIDC deployment environment' \
  'EXPECTED_CLOUD_ACCOUNT is required' \
  'AWS cloud_account must be a concrete 12-digit account ID' \
  '.spec.aws.account_id == $account'; do
  grep -Fq -- "${required}" "${resolver}" || {
    echo "AWS OIDC resolver is missing required validation: ${required}" >&2
    exit 1
  }
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
fixture="${tmpdir}/aws-oidc.json"
output="${tmpdir}/github-output"
jq -n \
  --arg account '081434641398' \
  '{apiVersion:"gitops.svc.plus/v1alpha1",kind:"GitHubActionsOIDCConfig",metadata:{environment:"uat",provider:"aws"},spec:{provider_url:"https://token.actions.githubusercontent.com",audience:"sts.amazonaws.com",aws:{account_id:$account,region:"ap-northeast-1",role_name:"GithubAction_IAC_Deploy_Role",role_arn:("arn:aws:iam::"+$account+":role/GithubAction_IAC_Deploy_Role")},subjects:["repo:ai-workspace-infra/platform-ops-toolkit:ref:refs/heads/main","repo:ai-workspace-infra/platform-ops-toolkit:ref:refs/tags/uat-daily-build-*","repo:ai-workspace-infra/platform-ops-toolkit:environment:uat"]}}' >"${fixture}"
GITOPS_AWS_OIDC_CONFIG="${fixture}" EXPECTED_DEPLOYMENT_ENV=uat \
  EXPECTED_CLOUD_ACCOUNT=081434641398 GITHUB_OUTPUT="${output}" bash "${resolver}"
grep -Fq 'role_arn=arn:aws:iam::081434641398:role/GithubAction_IAC_Deploy_Role' "${output}"
if GITOPS_AWS_OIDC_CONFIG="${fixture}" EXPECTED_DEPLOYMENT_ENV=uat \
  EXPECTED_CLOUD_ACCOUNT=950604983695 GITHUB_OUTPUT="${output}" bash "${resolver}" >/dev/null 2>&1; then
  echo "AWS OIDC resolver must reject an account that differs from the selected state account." >&2
  exit 1
fi

echo "aws_oidc_gitops_contract_test: PASS"
