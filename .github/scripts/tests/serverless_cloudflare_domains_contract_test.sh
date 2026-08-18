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
  "metadata": {"mode": "serverless"},
  "spec": {
    "runtime": {
      "mode": "serverless",
      "routing": {
        "dns": {
          "canonical_records": {
            "console-uat.onwalk.net": "console-serverless-uat.onwalk.net",
            "accounts-uat.onwalk.net": "accounts-serverless-uat.onwalk.net"
          }
        }
      }
    },
    "cloudflare": {
      "zone_name": "onwalk.net",
      "pages_project": "ai-workspace-portal-uat"
    },
    "serverless": {
      "console_host": "console-serverless-uat.onwalk.net",
      "accounts_host": "accounts-serverless-uat.onwalk.net",
      "billing_host": "billing-serverless-uat.onwalk.net",
      "cloud_run": {
        "billing_service": "https://uat-billing-service-1004637461064.asia-northeast1.run.app"
      },
      "frontend_router": {
        "worker_name": "frontend-router-uat"
      },
      "edge_gateway": {
        "boundaries": [
          {"id": "core", "display_name": "Edge Gateway Router Core", "worker_name": "edge-gateway-core-uat"}
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
body=""
url="${!#}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --request)
      method="$2"
      shift 2
      ;;
    --data)
      body="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\t%s\t%s\n' "${method}" "${url}" "${body}" >>"${MOCK_CURL_LOG}"
if [[ "${url}" == *'/zones?name='* ]]; then
  printf '%s' '{"success":true,"result":[{"id":"zone-1"}]}'
elif [[ "${url}" == *'/pages/projects/ai-workspace-portal-uat/domains'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[]}'
elif [[ "${url}" == *'/workers/domains'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[{"id":"billing-worker-domain","hostname":"billing-serverless-uat.onwalk.net","service":"edge-gateway-core-uat"},{"id":"accounts-alias-worker-domain","hostname":"accounts-uat.onwalk.net","service":"edge-gateway-core-uat"}]}'
elif [[ "${url}" == *'/rulesets?phase=http_request_origin'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[{"id":"ruleset-1","kind":"zone","phase":"http_request_origin"}]}'
elif [[ "${url}" == *'/rulesets/ruleset-1'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":{"id":"ruleset-1","rules":[{"ref":"existing_rule","action":"route","expression":"(http.host eq \\\"existing.example.com\\\")"}]}}'
elif [[ "${url}" == *'/dns_records?name=billing-serverless-uat.onwalk.net'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[{"id":"billing-cname","content":"uat-billing-service-1004637461064.asia-northeast1.run.app"}]}'
elif [[ "${url}" == *'/dns_records?name=console-uat.onwalk.net'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[{"id":"console-alias","content":"console-serverless-uat.onwalk.net"}]}'
elif [[ "${url}" == *'/dns_records?name=accounts-uat.onwalk.net'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[{"id":"accounts-alias","content":"accounts-serverless-uat.onwalk.net"}]}'
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
SERVERLESS_DNS_MODE="uat-records" \
"${reconciler}"

if grep -Fq $'POST\thttps://cloudflare.invalid/client/v4/accounts/account-1/pages/projects/ai-workspace-portal-uat/domains' "${test_dir}/curl.log"; then
  echo "Pages must not receive the Console custom domain" >&2
  exit 1
fi
worker_puts="$(grep -Fc $'PUT\thttps://cloudflare.invalid/client/v4/accounts/account-1/workers/domains' "${test_dir}/curl.log")"
test "${worker_puts}" -eq 3
worker_bodies="$(cut -f3 "${test_dir}/curl.log" | jq -s '[.[] | select(type == "object" and .hostname != null)]')"
if ! jq -e '
  ((map(select(.hostname == "billing-serverless-uat.onwalk.net")) | length) == 0)
  and ((map(select(.hostname == "console-uat.onwalk.net" and .service == "frontend-router-uat")) | length) == 1)
  and ((map(select(.hostname == "accounts-uat.onwalk.net")) | length) == 0)
' <<<"${worker_bodies}" >/dev/null; then
  echo "Unexpected Worker custom-domain bindings: ${worker_bodies}" >&2
  exit 1
fi
dns_deletes="$(grep -Fc $'DELETE\thttps://cloudflare.invalid/client/v4/zones/zone-1/dns_records/' "${test_dir}/curl.log")"
test "${dns_deletes}" -eq 1
cname_bodies="$(cut -f3 "${test_dir}/curl.log" | jq -s '[.[] | select(.type == "CNAME")]')"
test "$(jq 'length' <<<"${cname_bodies}")" -eq 2
jq -e 'all(.[]; .proxied == true) and any(.[]; .name == "billing-serverless-uat.onwalk.net" and .content == "uat-billing-service-1004637461064.asia-northeast1.run.app") and any(.[]; .name == "accounts-uat.onwalk.net" and .content == "accounts-serverless-uat.onwalk.net")' <<<"${cname_bodies}" >/dev/null
ruleset_bodies="$(cut -f3 "${test_dir}/curl.log" | jq -s '[.[] | select(.rules != null)]')"
test "$(jq 'length' <<<"${ruleset_bodies}")" -eq 1
jq -e '
  any(.[0].rules[]; .ref == "serverless_billing_cloud_run_origin" and
    .action_parameters.host_header == "uat-billing-service-1004637461064.asia-northeast1.run.app" and
    .action_parameters.origin.host == "uat-billing-service-1004637461064.asia-northeast1.run.app" and
    .action_parameters.sni.value == "uat-billing-service-1004637461064.asia-northeast1.run.app")
' <<<"${ruleset_bodies}" >/dev/null
echo "serverless_cloudflare_domains_contract_test: PASS"
