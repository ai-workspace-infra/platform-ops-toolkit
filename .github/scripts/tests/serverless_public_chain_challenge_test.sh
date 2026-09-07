#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/scripts/serverless_uat/verify_serverless_public_chain.sh"
test_dir="$(mktemp -d)"
trap 'rc=$?; rm -rf "${test_dir}"; exit ${rc}' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '104.21.79.67'
EOF

cat >"${test_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${!#}"
dump_header=""
write_status=false
request_method=GET
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dump-header) dump_header="$2"; shift 2 ;;
    --request) request_method="$2"; shift 2 ;;
    --write-out) write_status=true; shift 2 ;;
    *) shift ;;
  esac
done

status=403
headers=$'HTTP/2 403\r\ncf-mitigated: challenge\r\nserver: cloudflare\r\n\r\n'
if [[ "${EDGE_MODE:-}" == "runner" ]]; then
  if [[ "${request_method}" == "OPTIONS" ]]; then
    status=204
    headers=$'HTTP/2 204\r\nserver: cloudflare\r\ncf-ray: test-ray\r\naccess-control-allow-origin: https://console-serverless-prod.svc.plus\r\n\r\n'
  else
    headers=$'HTTP/2 403\r\nserver: cloudflare\r\ncf-ray: test-ray\r\n\r\n'
  fi
fi
if [[ "${url}" == "https://www.xworktech.com/" && "${ALIAS_STATUS:-403}" != "403" ]]; then
  status="${ALIAS_STATUS}"
  headers="$(printf 'HTTP/2 %s\r\n' "${status}")"
  if [[ "${status}" == 3* ]]; then
    headers+=$'\r\nLocation: https://console.xworktech.com/\r\n'
  fi
fi
if [[ "${url}" == https://www.xworktech.com/login || "${url}" == https://xworktech.com/login || "${url}" == https://www.xworktech.com/ai-workspace* || "${url}" == https://xworktech.com/ai-workspace* ]]; then
  status=302
  path="/${url#*://*/}"
  headers="$(printf 'HTTP/2 302\r\nLocation: %s%s\r\n' "${WEBSITE_DEST:-https://svc.plus}" "${path}")"
fi
if [[ "${dump_header}" == "-" ]]; then
  printf '%s' "${headers}"
elif [[ -n "${dump_header}" ]]; then
  printf '%s' "${headers}" >"${dump_header}"
fi
if [[ "${write_status}" == true ]]; then
  printf '%s' "${status}"
fi
EOF
chmod +x "${test_dir}/bin/dig" "${test_dir}/bin/curl"

cat >"${test_dir}/routing.json" <<'EOF'
{
  "metadata": {"environment": "prod"},
  "spec": {
    "serverless": {
      "console_host": "console-serverless-prod.svc.plus",
      "console_aliases": [],
      "frontend_router": {"website": {"hosts": ["xworktech.com", "www.xworktech.com"], "platform_origin": "https://svc.plus"}},
      "accounts_host": "accounts-serverless-prod.svc.plus",
      "billing_host": "billing-serverless-prod.svc.plus"
    }
  }
}
EOF

output="${test_dir}/output"
PATH="${test_dir}/bin:${PATH}" \
  CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/routing.json" \
  SERVERLESS_DNS_MODE=none \
  VERIFY_ATTEMPTS=1 \
  VERIFY_INTERVAL_SECONDS=0 \
  "${script}" >"${output}"

cat >"${test_dir}/runner-routing.json" <<'EOF'
{
  "metadata": {"environment": "prod"},
  "spec": {
    "serverless": {
      "console_host": "console-serverless-prod.svc.plus",
      "console_aliases": [],
      "frontend_router": {"website": {"hosts": [], "platform_origin": "https://svc.plus"}},
      "accounts_host": "accounts-serverless-prod.svc.plus",
      "billing_host": "billing-serverless-prod.svc.plus"
    }
  }
}
EOF

PATH="${test_dir}/bin:${PATH}" \
  CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/runner-routing.json" \
  SERVERLESS_DNS_MODE=none EDGE_MODE=runner \
  VERIFY_ATTEMPTS=1 VERIFY_INTERVAL_SECONDS=0 \
  "${script}" >"${output}"

grep -Fq 'Serverless edge chain verified behind Cloudflare challenge' "${output}"
# A directly served homepage passes; redirects and origin failures must not.
for status in 200 301 302 307 308 500; do
  result=0
  PATH="${test_dir}/bin:${PATH}" \
    CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/routing.json" \
    SERVERLESS_DNS_MODE=none VERIFY_ATTEMPTS=1 VERIFY_INTERVAL_SECONDS=0 \
    ALIAS_STATUS="${status}" bash "${script}" >"${output}" 2>&1 || result=$?
  if [[ "${status}" == 200 ]]; then
    [[ "${result}" == 0 ]] || { cat "${output}"; exit 1; }
  else
    [[ "${result}" != 0 ]] || { echo "Unexpected acceptance of alias HTTP ${status}" >&2; exit 1; }
    grep -Fq "https://www.xworktech.com/ HTTP ${status}" "${output}"
  fi
done
if PATH="${test_dir}/bin:${PATH}" CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/routing.json" \
  SERVERLESS_DNS_MODE=none VERIFY_ATTEMPTS=1 VERIFY_INTERVAL_SECONDS=0 \
  WEBSITE_DEST=https://console.xworktech.com bash "${script}" >"${output}" 2>&1; then
  echo "Website platform redirect to the wrong domain was accepted" >&2
  exit 1
fi
grep -Fq 'Website platform boundary failed:' "${output}"
echo "serverless_public_chain_challenge_test: PASS"
