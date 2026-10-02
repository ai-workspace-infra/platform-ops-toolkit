#!/usr/bin/env bash
set -euo pipefail

# The script half of this contract lives in
# iac_modules/scripts/pipeline/tests/gcp_runtime_reconcile_contract_test.sh.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${root_dir}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq 'name: Ensure declared GCP VMs are running' "${workflow}"
grep -Fq "steps.route.outputs.cloud_provider == 'gcp-cloud'" "${workflow}"
grep -Fq "steps.route.outputs.terraform_action == 'apply'" "${workflow}"
grep -Fq 'resources_manifest.json' "${workflow}"
grep -Fq 'infra/iac_modules/scripts/pipeline/ensure-gcp-vm-running.py' "${workflow}"

echo 'GCP runtime reconciliation contract passed.'
