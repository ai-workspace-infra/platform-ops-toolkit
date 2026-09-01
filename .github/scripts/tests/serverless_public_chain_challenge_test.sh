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

dump_header=""
write_status=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dump-header) dump_header="$2"; shift 2 ;;
    --write-out) write_status=true; shift 2 ;;
    *) shift ;;
  esac
done

headers=$'HTTP/2 403\r\ncf-mitigated: challenge\r\nserver: cloudflare\r\n\r\n'
if [[ "${dump_header}" == "-" ]]; then
  printf '%s' "${headers}"
elif [[ -n "${dump_header}" ]]; then
  printf '%s' "${headers}" >"${dump_header}"
fi
if [[ "${write_status}" == true ]]; then
  printf '%s' '403'
fi
EOF
chmod +x "${test_dir}/bin/dig" "${test_dir}/bin/curl"

cat >"${test_dir}/routing.json" <<'EOF'
{
  "metadata": {"environment": "prod"},
  "spec": {
    "serverless": {
      "console_host": "console-serverless-prod.svc.plus",
      "console_aliases": ["console-serverless-prod.xworktech.com"],
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

grep -Fq 'Serverless edge chain verified behind Cloudflare challenge' "${output}"
echo "serverless_public_chain_challenge_test: PASS"
