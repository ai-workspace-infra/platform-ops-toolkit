#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
resolver="${repo_root}/.github/scripts/platform-ops/provision/resolve_gitops_aws_oidc_config.sh"

test -x "${resolver}" || {
  echo "AWS OIDC GitOps resolver must be executable" >&2
  exit 1
}

for required in \
  "resources/svc.plus/\${{ steps.route.outputs.deployment_env }}/aws/github-actions-oidc.json" \
  "Resolve AWS OIDC deployment configuration from GitOps" \
  "steps.aws_oidc.outputs.role_arn" \
  "steps.aws_oidc.outputs.region" \
  "steps.aws_oidc.outputs.audience"; do
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
  'refs/tags/v*'; do
  grep -Fq -- "${required}" "${resolver}" || {
    echo "AWS OIDC resolver is missing required validation: ${required}" >&2
    exit 1
  }
done

echo "aws_oidc_gitops_contract_test: PASS"
