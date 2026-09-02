#!/usr/bin/env bash
set -euo pipefail

action="${BOOTSTRAP_ACTION:?BOOTSTRAP_ACTION is required}"
config_file="${GITOPS_AWS_OIDC_CONFIG:?GITOPS_AWS_OIDC_CONFIG is required}"
readonly expected_repository="ai-workspace-infra/platform-ops-toolkit"

case "${action}" in
  plan|apply) ;;
  *)
    echo "BOOTSTRAP_ACTION must be plan or apply, got: ${action}" >&2
    exit 1
    ;;
esac

for command in aws jq; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "${command} is required for AWS OIDC bootstrap recovery" >&2
    exit 1
  }
done

test -f "${config_file}" || {
  echo "GitOps AWS OIDC declaration not found: ${config_file}" >&2
  exit 1
}

test -n "${AWS_ACCESS_KEY_ID:-}" && test -n "${AWS_SECRET_ACCESS_KEY:-}" || {
  echo "Vault aws-bootstrap credentials must include AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." >&2
  exit 1
}

jq -e --arg repository "${expected_repository}" '
  .apiVersion == "gitops.svc.plus/v1alpha1" and
  .kind == "GitHubActionsOIDCConfig" and
  .metadata.environment == "prod" and
  .metadata.provider == "aws" and
  .spec.provider_url == "https://token.actions.githubusercontent.com" and
  .spec.audience == "sts.amazonaws.com" and
  (.spec.aws.account_id | test("^[0-9]{12}$")) and
  (.spec.aws.role_name | test("^[A-Za-z0-9+=,.@_-]+$")) and
  .spec.aws.role_arn == ("arn:aws:iam::" + .spec.aws.account_id + ":role/" + .spec.aws.role_name) and
  (.spec.subjects | type == "array") and
  (.spec.subjects | index("repo:" + $repository + ":ref:refs/heads/main")) and
  (.spec.subjects | index("repo:" + $repository + ":ref:refs/tags/v*"))
' "${config_file}" >/dev/null || {
  echo "GitOps AWS OIDC declaration failed the production recovery contract." >&2
  exit 1
}

account_id="$(jq -er '.spec.aws.account_id' "${config_file}")"
role_name="$(jq -er '.spec.aws.role_name' "${config_file}")"
role_arn="$(jq -er '.spec.aws.role_arn' "${config_file}")"
audience="$(jq -er '.spec.audience' "${config_file}")"
subjects="$(jq -ec '.spec.subjects' "${config_file}")"
provider_arn="arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"

caller_account="$(aws sts get-caller-identity --query Account --output text)"
test "${caller_account}" = "${account_id}" || {
  echo "Bootstrap credentials belong to AWS account ${caller_account}, expected ${account_id}." >&2
  exit 1
}

aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${provider_arn}" >/dev/null
aws iam get-role --role-name "${role_name}" --query 'Role.Arn' --output text | grep -Fx "${role_arn}" >/dev/null

policy_file="$(mktemp)"
jq -n \
  --arg provider_arn "${provider_arn}" \
  --arg audience "${audience}" \
  --argjson subjects "${subjects}" '
  {
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {Federated: $provider_arn},
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: {"token.actions.githubusercontent.com:aud": $audience},
        StringLike: {"token.actions.githubusercontent.com:sub": $subjects}
      }
    }]
  }
' > "${policy_file}"

echo "Validated GitOps OIDC declaration, AWS account, provider, and target role."
echo "Permitted subjects: $(jq -r '.[]' <<<"${subjects}" | paste -sd ', ' -)"

if [ "${action}" = "plan" ]; then
  echo "Plan complete. No AWS IAM change was made. Re-run with action=apply after reviewing this subject list."
  exit 0
fi

aws iam update-assume-role-policy \
  --role-name "${role_name}" \
  --policy-document "file://${policy_file}"

echo "Updated ${role_name} trust policy from the GitOps declaration."
