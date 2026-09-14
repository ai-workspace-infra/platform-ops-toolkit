#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"
script="${repo_root}/.github/scripts/xconnect-lab/reconcile-gateway-dns.sh"

test -x "${script}" || {
  echo 'Gateway DNS reconciler must be executable' >&2
  exit 1
}
bash -n "${script}"
grep -Fq 'XCONNECT_GATEWAY_DNS_NAME: ${{ env.EXTERNAL_GATEWAY_SERVER_NAME }}' "${workflow}"
grep -Fq 'XCONNECT_GATEWAY_DNS_TARGET: ${{ env.EXTERNAL_GATEWAY_HOST }}' "${workflow}"
grep -Fq 'proxied:false' "${script}"
grep -Fq 'tw-xconnect.svc.plus' "${script}"
grep -Fq 'public DNS visibility' "${script}"
if grep -Eq 'CLOUDFLARE_(API_TOKEN|ACCOUNT_ID).*GitOps|gitops.*CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)' "${workflow}"; then
  echo 'Cloudflare credentials must remain Vault-injected, not GitOps data' >&2
  exit 1
fi

echo 'xconnect_gateway_dns_contract_test: PASS'
