#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reconciler="${repo_root}/scripts/serverless_uat/reconcile_cloudflare_domains.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/routing.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "serverless"},
  "spec": {
    "runtime": {"mode": "serverless"},
    "cloudflare": {
      "zone_name": "onwalk.net",
      "pages_project": "ai-workspace-portal-uat"
    },
    "serverless": {
      "console_host": "console-cloudflare-uat.onwalk.net",
      "accounts_host": "accounts-cloudflare-uat.onwalk.net",
      "frontend_router": {
        "worker_name": "frontend-router-uat"
      },
      "edge_gateway": {
        "boundaries": [
          {"id": "core", "worker_name": "edge-gateway-core-uat"}
        ]
      }
    }
  }
}
EOF

cat >"${test_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
url="${!#}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --request)
      method="$2"
      shift 2
      ;;
    --data)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\t%s\n' "${method}" "${url}" >>"${MOCK_CURL_LOG}"
if [[ "${url}" == *'/zones?name='* ]]; then
  printf '%s' '{"success":true,"result":[{"id":"zone-1"}]}'
elif [[ "${url}" == *'/pages/projects/ai-workspace-portal-uat/domains'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[]}'
elif [[ "${url}" == *'/workers/domains'* && "${method}" == 'GET' ]]; then
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
"${reconciler}" >/dev/null

if grep -Fq $'POST\thttps://cloudflare.invalid/client/v4/accounts/account-1/pages/projects/ai-workspace-portal-uat/domains' "${test_dir}/curl.log"; then
  echo "Pages must not receive the Console custom domain" >&2
  exit 1
fi
worker_puts="$(grep -Fc $'PUT\thttps://cloudflare.invalid/client/v4/accounts/account-1/workers/domains' "${test_dir}/curl.log")"
test "${worker_puts}" -eq 2
echo "serverless_cloudflare_domains_contract_test: PASS"
