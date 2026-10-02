#!/usr/bin/env bash
# Explicit checkout paths allow testing independent PR branches together.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo "Usage: bash run_iam_tests.sh TOOLKIT_ROOT GITOPS_ROOT PLAYBOOKS_ROOT IAC_ROOT" >&2
  exit 2
fi
toolkit_root="$1"
gitops_root="$2"
playbooks_root="$3"
iac_root="$4"
python3 "$toolkit_root/scripts/tests/test_identity_bootstrap.py"
bash "$toolkit_root/scripts/tests/identity_bootstrap_contract_test.sh"
ruby "$gitops_root/tests/test_iam_integrations.rb"
python3 "$toolkit_root/scripts/tests/test_identity_cross_repo.py" --gitops-root "$gitops_root"
"${GRAFANA_TEST_PYTHON:-python3}" "$playbooks_root/tests/test_grafana_oidc_runtime.py"
module_dir="$iac_root/terraform-hcl-standard/aws-cloud/modules/oidc_federation"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/iam-tf-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp "$module_dir"/*.tf "$test_dir/"
cp "$module_dir/.terraform.lock.hcl" "$test_dir/"
cp -R "$module_dir/tests" "$test_dir/tests"
terraform -chdir="$test_dir" fmt -check -recursive
if [[ -n "${IAM_TEST_PLUGIN_DIR:-}" ]]; then
  terraform -chdir="$test_dir" init -backend=false -input=false -plugin-dir="$IAM_TEST_PLUGIN_DIR"
else
  terraform -chdir="$test_dir" init -backend=false -input=false
fi
terraform -chdir="$test_dir" validate
terraform -chdir="$test_dir" test
echo "IAM offline suite: PASS (live SSO/Vault acceptance still required)"
