#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${root_dir}/.github/workflows/selfhost-orchestrator.yml"
script="${root_dir}/.github/scripts/platform-ops/provision/platform-ops_provision_ensure-gcp-vm-running.py"

test -x "${script}" || { echo "runtime reconciliation script must be executable" >&2; exit 1; }
grep -Fq 'name: Ensure declared GCP VMs are running' "${workflow}"
grep -Fq "steps.route.outputs.cloud_provider == 'gcp-cloud'" "${workflow}"
grep -Fq "steps.route.outputs.terraform_action == 'apply'" "${workflow}"
grep -Fq 'resources_manifest.json' "${workflow}"
grep -Fq 'instances", "start"' "${script}"
grep -Fq 'never creates, replaces, or deletes' "${script}"

echo 'GCP runtime reconciliation contract passed.'
