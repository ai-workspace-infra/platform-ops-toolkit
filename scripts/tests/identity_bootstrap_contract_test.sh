#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
canonical="${repo_root}/scripts/cloud/bootstrap/iam/bootstrap_identity_kv.sh"
test -x "$canonical"
bash -n "$canonical"
grep -Fq 'kv/iam/' "$canonical"
grep -Fq 'vault kv put -cas=' "$canonical"
grep -Fq 'refusing to create a record' "$canonical"
grep -Fq 'mode 0600' "$canonical"
grep -Fq 'No value found at' "$canonical"

for wrapper in \
  scripts/cloud/bootstrap/gcp/bootstrap_gcp_iam_kv.sh \
  scripts/cloud/bootstrap/aws/bootstrap_aws_iam_kv.sh \
  scripts/cloud/bootstrap/Akamai-Cloud/bootstrap_linode_sso_kv.sh \
  scripts/cloud/bootstrap/vultr-VPS/bootstrap_vultr_sso_kv.sh \
  scripts/cloud/bootstrap/ucloud/bootstrap_ucloud_global_sso_kv.sh \
  scripts/cloud/bootstrap/iam/bootstrap_grafana_oidc_kv.sh; do
  test -x "${repo_root}/${wrapper}"
  bash -n "${repo_root}/${wrapper}"
  grep -Fq 'bootstrap_identity_kv.sh' "${repo_root}/${wrapper}"
done

if grep -Eiq 'echo ["`].*(payload_file|current_json|merged_file)["`]' "$canonical"; then
  echo "identity bootstrap must not print payload contents" >&2
  exit 1
fi
echo "identity_bootstrap_contract_test: PASS"
