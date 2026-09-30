#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

canonical_scripts=(
  scripts/cloud/bootstrap/aws/bootstrap_aws_auth_kv.sh
  scripts/cloud/bootstrap/aws/reconcile_github_oidc_trust.sh
  scripts/cloud/bootstrap/aws/adopt_github_oidc_terraform_state.sh
  scripts/cloud/bootstrap/gcp/bootstrap_gcp_auth_kv.sh
  scripts/cloud/bootstrap/gcp/bootstrap_shared_iac_state_kv.sh
  scripts/cloud/bootstrap/gcp/gcp_account_migration.sh
  scripts/cloud/bootstrap/gcp/resolve_github_oidc_config.sh
  scripts/cloud/bootstrap/iam/bootstrap_zitadel_kv.sh
  scripts/cloud/bootstrap/Akamai-Cloud/bootstrap_akamai_cloud_kv.sh
  scripts/cloud/bootstrap/Akamai-Cloud/bootstrap_akamai_oidc_roles.sh
  scripts/cloud/bootstrap/vultr-VPS/bootstrap_vultr_auth_kv.sh
  scripts/cloud/bootstrap/ucloud/bootstrap_ucloud_auth_kv.sh
)

for relative in "${canonical_scripts[@]}"; do
  path="${repo_root}/${relative}"
  test -x "${path}" || { echo "canonical bootstrap script is not executable: ${relative}" >&2; exit 1; }
  bash -n "${path}" || { echo "canonical bootstrap script has invalid shell syntax: ${relative}" >&2; exit 1; }
done

compatibility_wrappers=(
  scripts/gcp/bootstrap_gcp_auth_kv.sh
  scripts/gcp/bootstrap_shared_iac_state_kv.sh
  scripts/gcp/gcp_account_migration.sh
  scripts/iam/bootstrap_zitadel_kv.sh
  scripts/ucloud/bootstrap_ucloud_auth_kv.sh
  scripts/vault/bootstrap_akamai_cloud_kv.sh
  scripts/vault/bootstrap_akamai_oidc_roles.sh
  .github/scripts/aws/adopt_github_oidc_terraform_state.sh
  .github/scripts/aws/reconcile_github_oidc_trust.sh
  .github/scripts/gcp/resolve_github_oidc_config.sh
)

for relative in "${compatibility_wrappers[@]}"; do
  path="${repo_root}/${relative}"
  test -x "${path}" || { echo "compatibility wrapper is not executable: ${relative}" >&2; exit 1; }
  bash -n "${path}"
  grep -Fq 'scripts/cloud/bootstrap/' "${path}" || {
    echo "compatibility wrapper does not delegate to canonical tree: ${relative}" >&2
    exit 1
  }
done

aws_bootstrap="${repo_root}/scripts/cloud/bootstrap/aws/bootstrap_aws_auth_kv.sh"
for required in \
  'kv/CICD/<env>/aws-bootstrap' \
  'AWS_ACCESS_KEY_ID' \
  'AWS_SECRET_ACCESS_KEY' \
  'AWS_SESSION_TOKEN' \
  '--write|--apply' \
  'AWS_BOOTSTRAP_ACTION must be check or write' \
  'Vault authentication is required'; do
  grep -Fq -- "${required}" "${aws_bootstrap}" || {
    echo "AWS bootstrap helper missing contract: ${required}" >&2
    exit 1
  }
done

for forbidden in 'echo "${AWS_ACCESS_KEY_ID}' 'echo "${AWS_SECRET_ACCESS_KEY}' 'printf.*AWS_SECRET_ACCESS_KEY'; do
  if grep -Eq -- "${forbidden}" "${aws_bootstrap}"; then
    echo "AWS bootstrap helper must not print secret values: ${forbidden}" >&2
    exit 1
  fi
done

echo "cloud_bootstrap_layout_contract_test: PASS"
