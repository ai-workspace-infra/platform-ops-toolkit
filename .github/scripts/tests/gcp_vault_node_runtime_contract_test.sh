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
grep -Fq 'Adopt privileged shared external IP policy' "${workflow}"
grep -Fq 'projects/${PROJECT_ID}/policies/compute.vmExternalIpAccess' "${workflow}"
grep -Fq 'projects/${project_number}/policies/compute.vmExternalIpAccess' "${workflow}"
grep -Fq 'Shared external IP policy was not recorded in Terraform state' "${workflow}"
grep -Fq 'Shared external IP policy differs from GitOps' "${workflow}"
grep -Fq 'Adopt shared Vault HTTPS firewall' "${workflow}"
grep -Fq 'google_compute_firewall.vault_gateway_https' "${workflow}"
grep -Fq 'projects/${PROJECT_ID}/global/firewalls/${NETWORK_NAME}-vault-gateway-https' "${workflow}"
grep -Fq 'steps.config.outputs.network_name' "${workflow}"

echo 'GCP Vault VM runtime verification contract: OK'
