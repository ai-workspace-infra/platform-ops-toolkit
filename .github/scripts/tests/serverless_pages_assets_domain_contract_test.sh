#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reconciler="${repo_root}/scripts/serverless_uat/reconcile_cloudflare_domains.sh"
test_dir="$(mktemp -d)"
trap 'rc=$?; rm -rf "${test_dir}"; exit ${rc}' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/routing.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "serverless", "environment": "prod"},
  "spec": {
    "runtime": {"mode": "serverless", "routing": {"dns": {"canonical_records": {}}, "load-balancer": {}, "weight": {}}},
    "cloudflare": {
      "zone_name": "svc.plus",
      "pages_project": "ai-workspace-portal-prod",
      "static_cdn_url": "https://assets.svc.plus"
    },
    "serverless": {
      "console_host": "console-serverless-prod.svc.plus",
      "accounts_host": "accounts-serverless-prod.svc.plus",
      "billing_host": "billing-serverless-prod.svc.plus",
      "cloud_run": {"billing_service": "https://billing-service-uc.a.run.app"},
      "frontend_router": {"worker_name": "frontend-router-prod"},
      "edge_gateway": {"boundaries": [{"id": "core", "worker_name": "edge-gateway-core-prod"}]}
    }
  }
}
EOF

cat >"${test_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method="GET"
body=""
url="${!#}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --data) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\n' "${method}" "${url}" "${body}" >>"${MOCK_CURL_LOG}"
if [[ "${url}" == *'/zones?name=svc.plus'* ]]; then
  printf '%s' '{"success":true,"result":[{"id":"zone-1"}]}'
elif [[ "${url}" == *'/pages/projects/ai-workspace-portal-prod/domains'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[]}'
elif [[ "${url}" == *'/dns_records?name='* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[]}'
else
  printf '%s' '{"success":true,"result":{}}'
fi
EOF
chmod +x "${test_dir}/bin/curl"

PATH="${test_dir}/bin:${PATH}" \
MOCK_CURL_LOG="${test_dir}/curl.log" \
CLOUDFLARE_ACCOUNT_ID="account-1" \
CLOUDFLARE_API_TOKEN="test-token" \
CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/routing.json" \
CLOUDFLARE_API_BASE_OVERRIDE="https://cloudflare.invalid/client/v4" \
SERVERLESS_DNS_MODE="none" \
"${reconciler}"

grep -Fq $'POST\thttps://cloudflare.invalid/client/v4/accounts/account-1/pages/projects/ai-workspace-portal-prod/domains\t{"name":"assets.svc.plus"}' "${test_dir}/curl.log"
grep -Fq $'POST\thttps://cloudflare.invalid/client/v4/zones/zone-1/dns_records\t{"type":"CNAME","name":"assets.svc.plus","content":"ai-workspace-portal-prod.pages.dev"' "${test_dir}/curl.log"
echo "serverless_pages_assets_domain_contract_test: PASS"
