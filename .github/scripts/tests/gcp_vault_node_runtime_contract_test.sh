#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
workflow="${repo_root}/.github/workflows/gcp-iac-pipeline.yml"

test -s "${workflow}"
grep -Fq 'Verify declared Vault VM instances are running' "${workflow}"
grep -Fq "jq '.vault_nodes | length'" "${workflow}"
grep -Fq 'gcloud compute instances describe' "${workflow}"
grep -Fq '[[ "${status}" == RUNNING ]]' "${workflow}"
grep -Fq 'missing its declared public IPv4 address' "${workflow}"
grep -Fq "if: \${{ env.DEPLOY_ACTION == 'apply' }}" "${workflow}"

echo 'GCP Vault VM runtime verification contract: OK'
