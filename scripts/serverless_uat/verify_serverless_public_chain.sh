#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps manifest}"
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-18}"
VERIFY_INTERVAL_SECONDS="${VERIFY_INTERVAL_SECONDS:-10}"
serverless_dns_mode="${SERVERLESS_DNS_MODE:-none}"

case "${serverless_dns_mode}" in
  none|uat-records|prod-cutover)
    ;;
  *)
    echo "SERVERLESS_DNS_MODE must be one of: none, uat-records, prod-cutover" >&2
    exit 2
    ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v dig >/dev/null 2>&1 || { echo "dig is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
test -f "${CONFIG_FILE}" || { echo "GitOps routing manifest not found: ${CONFIG_FILE}" >&2; exit 1; }

is_success_status() {
  [[ "$1" =~ ^(200|301|302|307|308)$ ]]
}

is_cloudflare_challenge() {
  local headers="$1"
  grep -Eiq '^cf-mitigated:[[:space:]]*challenge' "${headers}"
}

is_cloudflare_challenge_text() {
  grep -Eiq '^cf-mitigated:[[:space:]]*challenge' <<<"$1"
}

probe_is_acceptable() {
  local status="$1" headers="$2"
  is_success_status "${status}" || is_cloudflare_challenge "${headers}"
}

environment="$(jq -er '.metadata.environment' "${CONFIG_FILE}")"
console_host="$(jq -er '.spec.serverless.console_host' "${CONFIG_FILE}")"
accounts_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"
billing_host="$(jq -er '.spec.serverless.billing_host' "${CONFIG_FILE}")"
canonical_console="console.svc.plus"
canonical_accounts="accounts.svc.plus"
if [[ "${environment}" != "prod" ]]; then
  canonical_console="console-${environment}.onwalk.net"
  canonical_accounts="accounts-${environment}.onwalk.net"
fi

if [[ "${serverless_dns_mode}" != "none" ]]; then
  console_probe_host="${canonical_console}"
  accounts_probe_host="${canonical_accounts}"
else
  console_probe_host="${console_host}"
  accounts_probe_host="${accounts_host}"
fi
origin="https://${console_probe_host}"
api_origin="https://${accounts_probe_host}"
probe_root="$(mktemp -d)"
trap 'rm -rf "${probe_root}"' EXIT

for ((attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++)); do
  console_dns="$(dig +short @1.1.1.1 "${console_probe_host}" | sed -n '1p')"
  accounts_dns="$(dig +short @1.1.1.1 "${accounts_probe_host}" | sed -n '1p')"
  billing_dns="$(dig +short @1.1.1.1 "${billing_host}" | sed -n '1p')"
  console_headers="${probe_root}/console.headers"
  console_status="$(curl --silent --show-error --dump-header "${console_headers}" --output /dev/null --write-out '%{http_code}' --max-time 20 "${origin}/" || true)"
  aliases_ready=true
  while IFS= read -r console_alias; do
    [[ -n "${console_alias}" ]] || continue
    alias_dns="$(dig +short @1.1.1.1 "${console_alias}" | sed -n '1p')"
    alias_headers="${probe_root}/alias-${console_alias//[^A-Za-z0-9]/_}.headers"
    alias_status="$(curl --silent --show-error --dump-header "${alias_headers}" --output /dev/null --write-out '%{http_code}' --max-time 20 "https://${console_alias}/" || true)"
    if [[ -z "${alias_dns}" ]] || ! probe_is_acceptable "${alias_status}" "${alias_headers}"; then
      aliases_ready=false
    fi
  done < <(jq -r '.spec.serverless.console_aliases[]? // empty' "${CONFIG_FILE}")
  preflight_headers="$(curl --silent --show-error --dump-header - --output /dev/null --max-time 20 \
    --request OPTIONS "${api_origin}/api/v1/health" \
    --header "Origin: ${origin}" \
    --header 'Access-Control-Request-Method: GET' \
    --header 'Access-Control-Request-Headers: Authorization, Content-Type' || true)"
  preflight_status="$(awk 'NR == 1 {print $2}' <<<"${preflight_headers}")"
  # Billing is exposed through the Edge Gateway Core custom domain. Probe the
  # service readiness contract, which is implemented by the deployed Go
  # service, instead of assuming the generic accounts /healthz path exists.
  billing_headers="$(curl --silent --show-error --dump-header - --output /dev/null --max-time 20 "https://${billing_host}/readyz" || true)"
  billing_status="$(awk 'NR == 1 {print $2}' <<<"${billing_headers}")"
  billing_route="$(awk 'BEGIN { IGNORECASE=1 } /^X-Upstream-Route:/ {sub(/\r$/, "", $2); print $2}' <<<"${billing_headers}" | tail -1)"

  full_chain_ready=false
  if is_success_status "${console_status}" && [[ "${preflight_status}" == "204" &&
        "${billing_status}" == "200" && "${billing_route}" == "cloud-run-billing" &&
        "${preflight_headers}" =~ [Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: ]]; then
    full_chain_ready=true
  fi

  edge_challenge_ready=false
  if is_cloudflare_challenge "${console_headers}" &&
     is_cloudflare_challenge_text "${preflight_headers}" &&
     is_cloudflare_challenge_text "${billing_headers}"; then
    edge_challenge_ready=true
  fi

  if [[ -n "${console_dns}" && -n "${accounts_dns}" && -n "${billing_dns}" &&
        "${aliases_ready}" == true &&
        ( "${full_chain_ready}" == true || "${edge_challenge_ready}" == true ) ]]; then
    if [[ "${full_chain_ready}" == true ]]; then
      echo "Serverless public chain verified: Console=${console_probe_host}, Accounts=${accounts_probe_host}, Billing=${billing_host} via ${billing_route}; CORS preflight 204 (dns_mode=${serverless_dns_mode})"
    else
      echo "Serverless edge chain verified behind Cloudflare challenge: Console=${console_probe_host}, Accounts=${accounts_probe_host}, Billing=${billing_host}; DNS and protected edge responses are ready (dns_mode=${serverless_dns_mode})"
    fi
    exit 0
  fi

  echo "Waiting for serverless public chain (${attempt}/${VERIFY_ATTEMPTS}): console=${console_probe_host} dns=${console_dns:-missing}, aliases_ready=${aliases_ready}, accounts=${accounts_probe_host} dns=${accounts_dns:-missing}, billing=${billing_host} dns=${billing_dns:-missing}, console_http=${console_status}, preflight=${preflight_status:-missing}, billing_http=${billing_status:-missing}, billing_route=${billing_route:-missing}" >&2
  if (( attempt < VERIFY_ATTEMPTS )); then
    sleep "${VERIFY_INTERVAL_SECONDS}"
  fi
done

echo "Serverless public chain verification failed for ${console_probe_host} and ${accounts_probe_host}." >&2
exit 1
