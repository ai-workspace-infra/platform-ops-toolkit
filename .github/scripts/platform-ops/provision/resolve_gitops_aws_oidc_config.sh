#!/usr/bin/env bash
set -euo pipefail

config_file="${GITOPS_AWS_OIDC_CONFIG:?GITOPS_AWS_OIDC_CONFIG is required}"
expected_environment="${EXPECTED_DEPLOYMENT_ENV:?EXPECTED_DEPLOYMENT_ENV is required}"
readonly expected_repository="ai-workspace-infra/platform-ops-toolkit"

# Immutable release references are environment-specific. Production releases
# are tagged v*, whereas the daily UAT pipeline deliberately uses its own
# uat-daily-build-* namespace.
case "${expected_environment}" in
  prod)
    required_tag_subject="repo:${expected_repository}:ref:refs/tags/v*"
    ;;
  uat)
    required_tag_subject="repo:${expected_repository}:ref:refs/tags/uat-daily-build-*"
    ;;
  *)
    echo "Unsupported AWS OIDC deployment environment: ${expected_environment}" >&2
    exit 1
    ;;
esac

test -f "${config_file}" || {
  echo "GitOps AWS OIDC declaration not found: ${config_file}" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required to read the GitOps AWS OIDC declaration" >&2
  exit 1
}

jq -e \
  --arg environment "${expected_environment}" \
  --arg repository "${expected_repository}" '
  .apiVersion == "gitops.svc.plus/v1alpha1" and
  .kind == "GitHubActionsOIDCConfig" and
  .metadata.environment == $environment and
  .metadata.provider == "aws" and
  .spec.provider_url == "https://token.actions.githubusercontent.com" and
  .spec.audience == "sts.amazonaws.com" and
  (.spec.aws.account_id | test("^[0-9]{12}$")) and
  (.spec.aws.region | test("^[a-z]+-[a-z]+-[0-9]+$")) and
  (.spec.aws.role_name | test("^[A-Za-z0-9+=,.@_-]+$")) and
  .spec.aws.role_arn == ("arn:aws:iam::" + .spec.aws.account_id + ":role/" + .spec.aws.role_name) and
  (.spec.subjects | type == "array") and
  (.spec.subjects | index("repo:" + $repository + ":ref:refs/heads/main")) and
  (.spec.subjects | index($required_tag_subject))
' --arg required_tag_subject "${required_tag_subject}" "${config_file}" >/dev/null || {
  echo "GitOps AWS OIDC declaration failed the ${expected_environment} trust contract: ${config_file}" >&2
  exit 1
}

role_arn="$(jq -er '.spec.aws.role_arn' "${config_file}")"
region="$(jq -er '.spec.aws.region' "${config_file}")"
audience="$(jq -er '.spec.audience' "${config_file}")"

{
  echo "role_arn=${role_arn}"
  echo "region=${region}"
  echo "audience=${audience}"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

echo "Resolved AWS OIDC deployment configuration for ${expected_environment}; role and audience were validated without reading credentials."
