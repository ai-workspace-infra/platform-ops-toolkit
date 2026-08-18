#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reconciler="${repo_root}/.github/scripts/platform-ops/dns/platform-ops_sit_all_in_one_dns_reconcile.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/bin"
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
if [[ "${url}" == *'/zones?name='* ]]; then
  printf '%s' '{"success":true,"result":[{"id":"zone-1"}]}'
elif [[ "${method}" == "GET" ]]; then
  printf '%s' '{"success":true,"result":[]}'
else
  printf '%s' '{"success":true,"result":{"id":"record-1"}}'
fi
EOF
chmod +x "${test_dir}/bin/curl"

cat >"${test_dir}/cmdb.json" <<'EOF'
{
  "all-in-one-sit.onwalk.net": {
    "ip": "45.77.128.182",
    "groups": ["all_in_one", "web_saas", "agent_proxy", "database"]
  }
}
EOF

output="$({
  PATH="${test_dir}/bin:${PATH}" \
  MOCK_CURL_LOG="${test_dir}/curl.log" \
  CLOUDFLARE_DNS_API_TOKEN="test-token" \
  CLOUDFLARE_API_BASE_OVERRIDE="https://cloudflare.invalid/client/v4" \
  DEPLOY_ENV="sit" \
  SOURCE_DOMAIN_BASE="svc.plus" \
  TARGET_DOMAIN_BASE="onwalk.net" \
  CMDB_FILE="${test_dir}/cmdb.json" \
  "${reconciler}"
} 2>&1)"

for record_name in console-selfhost-sit accounts-selfhost-sit billing-selfhost-sit postgresql-selfhost-sit agent-proxy-selfhost-sit; do
  grep -Fq "Created ${record_name}.onwalk.net -> 45.77.128.182 (A)" <<<"${output}"
done
grep -Fq 'completed for 5 records' <<<"${output}"

cut -f3 "${test_dir}/curl.log" | jq -s -e \
  'map(select(.type == "A")) | length == 5 and all(.[]; .content == "45.77.128.182")' >/dev/null

echo "platform_ops_sit_all_in_one_dns_test: PASS"
