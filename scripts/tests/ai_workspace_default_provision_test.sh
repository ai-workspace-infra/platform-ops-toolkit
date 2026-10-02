#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${root_dir}/.github/workflows/gcp-uat-workload-sequence.yml"

grep -Fq 'provision_ai_workspace:' "${workflow}"
grep -Fq 'default: false' "${workflow}"
grep -Fq 'if: ${{ inputs.provision_ai_workspace == true }}' "${workflow}"
grep -Fq 'gcp_resource_manifest: resources/xworktech.com/uat/gcp/ai-workspace-workload.yaml' "${workflow}"
grep -Fq 'needs: [web-saas, ai-workspace]' "${workflow}"
grep -Fq "needs.ai-workspace.result == 'success'" "${workflow}"

echo 'ai_workspace_default_provision_test: PASS'
