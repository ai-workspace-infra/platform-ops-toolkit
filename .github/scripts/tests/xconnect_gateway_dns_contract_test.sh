#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"
grep -Fq "default: 'a0185e61fc2b41ac4dbd40c8037016aaef1b3973'" "${workflow}"
grep -Fq "DNS_ENVIRONMENT: uat" "${workflow}"
grep -Fq 'DNS_ZONE: svc.plus' "${workflow}"
grep -Fq 'DNS_RECORD_NAME: ${{ env.EXTERNAL_GATEWAY_SERVER_NAME }}' "${workflow}"
grep -Fq 'DNS_TARGET_IP: ${{ env.EXTERNAL_GATEWAY_HOST }}' "${workflow}"
grep -Fq 'DNS_CHECKPOINT_PATH: ${{ runner.temp }}/xconnect-gateway-dns-checkpoint.json' "${workflow}"
grep -Fq 'python3 iac_modules/scripts/pipeline/cloudflare-gateway-dns-upsert.py' "${workflow}"
if grep -Fq '.github/scripts/xconnect-lab/reconcile-gateway-dns.sh' "${workflow}"; then
  echo 'Gateway DNS caller must use the merged iac_modules owner' >&2
  exit 1
fi
if grep -Eq 'CLOUDFLARE_(API_TOKEN|ACCOUNT_ID).*GitOps|gitops.*CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)' "${workflow}"; then
  echo 'Cloudflare credentials must remain Vault-injected, not GitOps data' >&2
  exit 1
fi

echo 'xconnect_gateway_dns_contract_test: PASS'
