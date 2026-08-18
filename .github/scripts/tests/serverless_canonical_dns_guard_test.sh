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
      "frontend_router": {"worker_name": "frontend-router-uat"},
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
    *)
      shift
      ;;
  esac
done

printf '%s\t%s\n' "${method}" "${url}" >>"${MOCK_CURL_LOG}"
if [[ "${url}" == *'console-uat.onwalk.net'* || "${url}" == *'accounts-uat.onwalk.net'* ]]; then
  echo "canonical DNS was touched while SERVERLESS_DNS_MODE=none: ${url}" >&2
  exit 1
elif [[ "${url}" == *'/zones?name='* ]]; then
  printf '%s' '{"success":true,"result":[{"id":"zone-1"}]}'
elif [[ "${url}" == *'/pages/projects/ai-workspace-portal-uat/domains'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[]}'
elif [[ "${url}" == *'/workers/domains'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[]}'
elif [[ "${url}" == *'/rulesets?per_page=50' && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":[{"id":"ruleset-1","kind":"zone","phase":"http_request_origin"}]}'
elif [[ "${url}" == *'/rulesets/ruleset-1'* && "${method}" == 'GET' ]]; then
  printf '%s' '{"success":true,"result":{"id":"ruleset-1","rules":[]}}'
elif [[ "${url}" == *'/dns_records?name=billing-serverless-uat.onwalk.net'* && "${method}" == 'GET' ]]; then
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

if grep -Eq 'console-uat\.onwalk\.net|accounts-uat\.onwalk\.net' "${test_dir}/curl.log"; then
  echo "Canonical DNS was modified during a normal serverless deployment" >&2
  exit 1
fi

echo "serverless_canonical_dns_guard_test: PASS"
