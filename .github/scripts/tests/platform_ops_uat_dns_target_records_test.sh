#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reconciler="${repo_root}/.github/scripts/platform-ops/dns/platform-ops_uat_dns_reconcile.sh"
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
elif [[ "${method}" == "GET" ]]; then
  printf '%s' '{"success":true,"result":[]}'
else
  printf '%s' '{"success":true,"result":{"id":"record-1"}}'
fi
EOF
chmod +x "${test_dir}/bin/curl"

cat >"${test_dir}/routing.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "selfhost"},
  "spec": {
    "runtime": {
      "mode": "selfhost",
      "routing": {
        "dns": {
          "control_plane": "cloudflare-dns",
          "ttl_seconds": 60,
          "canonical_records": {
            "console-uat.onwalk.net": "console-vps-uat.onwalk.net",
            "accounts-uat.onwalk.net": "accounts-vps-uat.onwalk.net"
          }
        },
        "load-balancer": {"strategy": "dns-only"},
        "weight": {"selfhost": 100, "serverless": 0}
      }
    },
    "cloudflare": {"zone_name": "onwalk.net"}
  }
}
EOF

cat >"${test_dir}/cmdb.json" <<'EOF'
{
  "console-uat.onwalk.net": {
    "ip": "45.77.128.182",
    "groups": ["web_saas"]
  }
}
EOF

output="$({
  PATH="${test_dir}/bin:${PATH}" \
  MOCK_CURL_LOG="${test_dir}/curl.log" \
  CLOUDFLARE_DNS_API_TOKEN="test-token" \
  CLOUDFLARE_API_BASE_OVERRIDE="https://cloudflare.invalid/client/v4" \
  DEPLOY_ENV="uat" \
  SOURCE_DOMAIN_BASE="svc.plus" \
  TARGET_DOMAIN_BASE="onwalk.net" \
  CMDB_FILE="${test_dir}/cmdb.json" \
  GITOPS_ROUTING_CONFIG="${test_dir}/routing.json" \
  "${reconciler}"
} 2>&1)"

grep -Fq 'Created console-vps-uat.onwalk.net -> 45.77.128.182 (A)' <<<"${output}"
grep -Fq 'Created accounts-vps-uat.onwalk.net -> 45.77.128.182 (A)' <<<"${output}"
grep -Fq 'Created console-uat.onwalk.net -> console-vps-uat.onwalk.net (CNAME)' <<<"${output}"
grep -Fq 'Created accounts-uat.onwalk.net -> accounts-vps-uat.onwalk.net (CNAME)' <<<"${output}"
grep -Fq 'completed for 4 GitOps-declared records' <<<"${output}"

cut -f3 "${test_dir}/curl.log" | jq -s -e \
  'any(.[]; .type == "A" and .name == "console-vps-uat.onwalk.net" and .content == "45.77.128.182")' >/dev/null
cut -f3 "${test_dir}/curl.log" | jq -s -e \
  'any(.[]; .type == "A" and .name == "accounts-vps-uat.onwalk.net" and .content == "45.77.128.182")' >/dev/null

echo "platform_ops_uat_dns_target_records_test: PASS"
