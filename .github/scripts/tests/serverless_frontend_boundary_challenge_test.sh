#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/bin"
cat >"${test_root}/bin/jq" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *metadata.environment*) printf '%s\n' prod ;;
  *spec.serverless.console_host*) printf '%s\n' console-serverless-prod.svc.plus ;;
  *spec.cloudflare.static_cdn_url*) printf '%s\n' '' ;;
  *) exit 1 ;;
esac
EOF
cat >"${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
headers=''
output='/dev/null'
while (($#)); do
  case "$1" in
    --dump-header) headers="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    *) shift ;;
  esac
done
cat >"${headers}" <<'HEADERS'
HTTP/2 403
cf-mitigated: challenge

HEADERS
: >"${output}"
printf '%s' 403
EOF
chmod +x "${test_root}/bin/jq" "${test_root}/bin/curl"

config_file="${test_root}/routing.json"
printf '%s\n' '{}' >"${config_file}"

output="$(
  PATH="${test_root}/bin:${PATH}" \
  CLOUDFLARE_BOUNDARY_CONFIG="${config_file}" \
  VERIFY_ATTEMPTS=1 \
  VERIFY_INTERVAL_SECONDS=0 \
  bash "${repo_root}/.github/scripts/serverless/verify_frontend_boundary_assets.sh"
)"

grep -Fq 'behind Cloudflare challenge' <<<"${output}"
echo "serverless_frontend_boundary_challenge_test: PASS"
