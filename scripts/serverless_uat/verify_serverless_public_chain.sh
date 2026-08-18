#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps manifest}"
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-18}"
VERIFY_INTERVAL_SECONDS="${VERIFY_INTERVAL_SECONDS:-10}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v dig >/dev/null 2>&1 || { echo "dig is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
test -f "${CONFIG_FILE}" || { echo "GitOps routing manifest not found: ${CONFIG_FILE}" >&2; exit 1; }

environment="$(jq -er '.metadata.environment' "${CONFIG_FILE}")"
console_host="$(jq -er '.spec.serverless.console_host' "${CONFIG_FILE}")"
accounts_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"
canonical_console="console.svc.plus"
canonical_accounts="accounts.svc.plus"
if [[ "${environment}" != "prod" ]]; then
  canonical_console="console-${environment}.onwalk.net"
  canonical_accounts="accounts-${environment}.onwalk.net"
fi
origin="https://${canonical_console}"
api_origin="https://${canonical_accounts}"

for ((attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++)); do
  console_dns="$(dig +short @1.1.1.1 "${canonical_console}" | sed -n '1p')"
  accounts_dns="$(dig +short @1.1.1.1 "${canonical_accounts}" | sed -n '1p')"
  console_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 20 "${origin}/" || true)"
  preflight_headers="$(curl --silent --show-error --dump-header - --output /dev/null --max-time 20 \
    --request OPTIONS "${api_origin}/api/v1/health" \
    --header "Origin: ${origin}" \
    --header 'Access-Control-Request-Method: GET' \
    --header 'Access-Control-Request-Headers: Authorization, Content-Type' || true)"
  preflight_status="$(awk 'NR == 1 {print $2}' <<<"${preflight_headers}")"

  if [[ -n "${console_dns}" && -n "${accounts_dns}" &&
        "${console_status}" =~ ^(200|301|302|307|308)$ && "${preflight_status}" == "204" &&
        "${preflight_headers}" =~ [Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: ]]; then
    echo "Serverless public chain verified: ${canonical_console} -> ${console_host} -> ${accounts_host} -> ${canonical_accounts} (CORS preflight 204)"
    exit 0
  fi

  echo "Waiting for serverless public chain (${attempt}/${VERIFY_ATTEMPTS}): console=${canonical_console} dns=${console_dns:-missing}, accounts=${canonical_accounts} dns=${accounts_dns:-missing}, console_http=${console_status}, preflight=${preflight_status:-missing}" >&2
  if (( attempt < VERIFY_ATTEMPTS )); then
    sleep "${VERIFY_INTERVAL_SECONDS}"
  fi
done

echo "Serverless public chain verification failed for ${canonical_console} and ${canonical_accounts}." >&2
exit 1
