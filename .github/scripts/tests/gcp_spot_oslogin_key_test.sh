#!/usr/bin/env bash
set -euo pipefail

# The key registration and VM start behaviour is tested next to the scripts, in
# iac_modules/scripts/pipeline/tests/gcp_spot_oslogin_key_test.sh. This keeps
# the step order in the provision job honest.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${root_dir}/.github/workflows/selfhost-orchestrator.yml"

# Workflow wiring: after the VMs are running, before the inventory.
python3 - "${workflow}" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
running = text.index("- name: Ensure declared GCP VMs are running")
refresh = text.index("- name: Refresh Terraform outputs after starting VMs")
register = text.index("- name: Register the deploy key for OS Login Spot VMs")
inventory = text.index("- name: generate.py inventory")
assert running < refresh < register < inventory, "VM start, output refresh, OS Login, then inventory"
assert "id: gcp_runtime" in text[running:refresh]
refresh_step = text[refresh:register]
assert "steps.gcp_runtime.outputs.started == 'true'" in refresh_step
assert "run: terraform apply -refresh-only -input=false -auto-approve -no-color" in refresh_step
assert "working-directory: ${{ steps.route.outputs.env_dir }}" in refresh_step
step = text[register:inventory]
for needle in (
    "steps.route.outputs.cloud_provider == 'gcp-cloud'",
    "steps.route.outputs.terraform_action == 'apply'",
    "GCP_PROJECT_ID: ${{ steps.gcp_oidc.outputs.project_id }}",
    "/resources_manifest.json",
    "infra/iac_modules/scripts/pipeline/register-gcp-oslogin-key.sh",
):
    assert needle in step, needle
PY

echo "GCP Spot OS Login deploy-key tests passed."
