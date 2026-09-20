#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_iac-self-check.py"
fixture_root="$(mktemp -d)"

mkdir -p "${fixture_root}/iac_modules/terraform-hcl-standard/akamai-cloud/modules/compute"
mkdir -p "${fixture_root}/gitops/resources/svc.plus/uat/akamai"
touch "${fixture_root}/iac_modules/terraform-hcl-standard/akamai-cloud/main.tf"
cat > "${fixture_root}/gitops/resources/svc.plus/uat/akamai/web-saas.yaml" <<'EOF'
global:
  provider: akamai-cloud
  region: us-east
  workspace: web-saas
hosts:
  - name: web-saas-uat-ak
    type: g6-standard-2
    host_vars:
      service_domains:
        - console-uat.onwalk.net
EOF

report="${fixture_root}/report.json"
summary="${fixture_root}/summary.md"
python3 "${script}" \
  --registry "${repo_root}/config/iac_provider_registry.json" \
  --defaults "${repo_root}/config/iac_environment_defaults.json" \
  --iac-root "${fixture_root}/iac_modules" \
  --gitops-root "${fixture_root}/gitops" \
  --environment uat \
  --project svc.plus \
  --provider akamai-cloud \
  --output-json "${report}" \
  --summary-file "${summary}"

python3 - "${report}" "${summary}" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
summary = open(sys.argv[2], encoding="utf-8").read()
assert report["status"] == "PASS", report
assert report["terraform_tree"] == "akamai-cloud", report
assert report["regions"] == ["us-east"], report
assert "web-saas-uat-ak" in report["resources"], report
assert "g6-standard-2" in report["resources"], report
assert "console-uat.onwalk.net" in report["services"], report
assert "dry-run only" in summary
assert "terraform/uat/platform-ops-toolkit/akamai-cloud/manbuzhe2026/self-check/terraform.tfstate" in summary
PY

if python3 "${script}" \
  --registry "${repo_root}/config/iac_provider_registry.json" \
  --defaults "${repo_root}/config/iac_environment_defaults.json" \
  --iac-root "${fixture_root}/iac_modules" \
  --gitops-root "${fixture_root}/gitops" \
  --environment uat \
  --project svc.plus \
  --provider ulighthost \
  --output-json "${fixture_root}/existing.json"; then
  echo "existing-resource provider must fail the Terraform self-check" >&2
  exit 1
fi

echo "platform_ops_iac_self_check_contract_test: PASS"
