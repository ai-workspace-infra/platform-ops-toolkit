#!/usr/bin/env bash
# Contract test for the store/startup review-readiness post-deploy check
# (skills/engineering-standards/store-and-startup-homepage-spec).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/scripts/serverless_uat/verify_brand_site_review_readiness.sh"
test_dir="$(mktemp -d)"
trap 'rc=$?; rm -rf "${test_dir}"; exit ${rc}' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/bin/dig" <<'EOF_DIG'
#!/usr/bin/env bash
printf '%s\n' '104.21.79.67'
EOF_DIG

# Stub curl: behaviour is driven by MODE so each case exercises one failure.
cat >"${test_dir}/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
out=""
write=""
while [[ "$#" -gt 1 ]]; do
  case "$1" in
    --output|-o) out="$2"; shift 2 ;;
    --write-out|-w) write="$2"; shift 2 ;;
    *) shift ;;
  esac
done
path="/${url#*://*/}"
[[ "${url}" == */ ]] && path="/"
status=200
location=""
body="<html><body>XWork Technologies LLC support@xworktech.com © 2026 XWork Technologies LLC</body></html>"
case "${path}" in
  /robots.txt) body=$'User-agent: *\nAllow: /\nSitemap: https://xworktech.com/sitemap.xml' ;;
  /sitemap.xml) body='<urlset><url><loc>https://xworktech.com/</loc></url></urlset>' ;;
esac
case "${MODE:-ok}" in
  redirect_off_domain) [[ "${path}" == "/products/xworkmate" ]] && { status=302; location="https://svc.plus/products/xworkmate"; } ;;
  redirect_same_domain) [[ "${path}" == "/docs" ]] && { status=307; location="https://xworktech.com/support"; } ;;
  missing_legal_name) [[ "${path}" == "/" ]] && body="<html>Acme</html>" ;;
  gmail) [[ "${path}" == "/contact" ]] && body="<html>XWork Technologies LLC someone@gmail.com</html>" ;;
  legacy_copyright) [[ "${path}" == "/" ]] && body="<html>XWork Technologies LLC © 2026 onwalk.net</html>" ;;
  challenge) status=403; body="Just a moment..." ;;
  no_sitemap) [[ "${path}" == "/sitemap.xml" ]] && status=404 ;;
esac
[[ -n "${out}" ]] && printf '%s' "${body}" >"${out}"
if [[ "${write}" == *"%{http_code}"* ]]; then
  printf '%s %s' "${status}" "${location}"
fi
EOF_CURL
chmod +x "${test_dir}/bin/dig" "${test_dir}/bin/curl"

cat >"${test_dir}/routing.json" <<'EOF_JSON'
{"metadata":{"environment":"prod"},"spec":{"serverless":{"frontend_router":{"website":{"hosts":["xworktech.com"],"platform_origin":"https://svc.plus"}}}}}
EOF_JSON

run() {
  MODE="$1" PATH="${test_dir}/bin:${PATH}" CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/routing.json" \
    VERIFY_ATTEMPTS=1 VERIFY_INTERVAL_SECONDS=0 bash "${script}" >"${test_dir}/out.log" 2>&1
}

expect_pass() {
  run "$1" || { cat "${test_dir}/out.log" >&2; echo "expected MODE=$1 to pass" >&2; exit 1; }
}
expect_fail() {
  if run "$1"; then echo "expected MODE=$1 to fail" >&2; exit 1; fi
  grep -Fq "$2" "${test_dir}/out.log" || { cat "${test_dir}/out.log" >&2; echo "MODE=$1 output missing: $2" >&2; exit 1; }
}

expect_pass ok
expect_fail redirect_off_domain "leaves xworktech.com"
expect_fail redirect_same_domain "expected 200"
expect_fail missing_legal_name "legal name"
expect_fail gmail "personal mailbox"
expect_fail legacy_copyright "legacy copyright"
expect_fail no_sitemap "sitemap.xml"
# A runner-side Cloudflare challenge is a warning, not a failure, so a
# datacenter-IP challenge cannot block an otherwise healthy deploy.
expect_pass challenge
grep -Fq "warning" "${test_dir}/out.log" || { echo "challenge should emit a warning" >&2; exit 1; }
BRAND_CHECK_STRICT=true MODE=challenge PATH="${test_dir}/bin:${PATH}" CLOUDFLARE_BOUNDARY_CONFIG="${test_dir}/routing.json" \
  VERIFY_ATTEMPTS=1 VERIFY_INTERVAL_SECONDS=0 bash "${script}" >/dev/null 2>&1 && { echo "strict mode should fail on a challenge" >&2; exit 1; }

echo "serverless_brand_site_review_readiness_test: PASS"
