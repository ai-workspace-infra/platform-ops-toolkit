#!/usr/bin/env bash
set -euo pipefail

# Reconcile the public Cloudflare entry points declared by the serverless
# EdgeRoutingConfig. Pages custom domains own the console hostname; the core
# Worker owns the accounts hostname while the auth/admin route boundaries keep
# their more-specific routes on that same hostname.

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps manifest}"
CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE_OVERRIDE:-https://api.cloudflare.com/client/v4}"

: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
test -f "${CONFIG_FILE}" || { echo "GitOps routing manifest not found: ${CONFIG_FILE}" >&2; exit 1; }

jq -e '
  .kind == "EdgeRoutingConfig"
  and .metadata.mode == "serverless"
  and .spec.runtime.mode == "serverless"
' "${CONFIG_FILE}" >/dev/null || {
  echo "Cloudflare domain reconciliation requires runtime.mode=serverless" >&2
  exit 1
}

zone_name="$(jq -er '.spec.cloudflare.zone_name' "${CONFIG_FILE}")"
pages_project="$(jq -er '.spec.cloudflare.pages_project' "${CONFIG_FILE}")"
console_host="$(jq -er '.spec.serverless.console_host' "${CONFIG_FILE}")"
accounts_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"
core_worker="$(jq -er '.spec.serverless.edge_gateway.boundaries[] | select(.id == "core") | .worker_name' "${CONFIG_FILE}")"

api_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local response
  local -a curl_args=(
    --fail-with-body
    --silent
    --show-error
    --retry 2
    --connect-timeout 10
    --max-time 30
    --request "${method}"
    --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    --header "Content-Type: application/json"
  )
  if [[ -n "${body}" ]]; then
    curl_args+=(--data "${body}")
  fi
  if ! response="$(curl "${curl_args[@]}" "${url}")"; then
    echo "Cloudflare API request failed: ${method} ${url}" >&2
    return 1
  fi
  if ! jq -e '.success == true' >/dev/null <<<"${response}"; then
    echo "Cloudflare API returned success=false: ${method} ${url}" >&2
    jq -c '.errors // .messages // []' <<<"${response}" >&2 || true
    return 1
  fi
  printf '%s' "${response}"
}

zone_response="$(api_request GET "${CLOUDFLARE_API_BASE}/zones?name=${zone_name}&status=active")"
zone_id="$(jq -er '.result | if length == 1 then .[0].id else error("expected exactly one active zone") end' <<<"${zone_response}")"

reconcile_pages_domain() {
  local domains_url="${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${pages_project}/domains?per_page=100"
  local domains_response
  local existing
  domains_response="$(api_request GET "${domains_url}")"
  existing="$(jq -r --arg hostname "${console_host}" 'first(.result[]? | select(.name == $hostname) | [.name, (.status // "unknown")] | @tsv) // empty' <<<"${domains_response}")"
  if [[ -n "${existing}" ]]; then
    echo "Pages custom domain present: ${existing}"
    return
  fi

  api_request POST "${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${pages_project}/domains" \
    "$(jq -cn --arg name "${console_host}" '{name: $name}')" >/dev/null
  echo "Pages custom domain attached: ${console_host} -> ${pages_project}"
}

reconcile_worker_domain() {
  local domains_url="${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains?per_page=100"
  local domains_response
  local existing
  local body
  domains_response="$(api_request GET "${domains_url}")"
  existing="$(jq -r --arg hostname "${accounts_host}" --arg service "${core_worker}" '
    first(.result[]? | select(.hostname == $hostname and .service == $service) | [.hostname, .service] | @tsv) // empty
  ' <<<"${domains_response}")"
  if [[ -n "${existing}" ]]; then
    echo "Worker custom domain present: ${existing}"
    return
  fi

  body="$(jq -cn \
    --arg hostname "${accounts_host}" \
    --arg service "${core_worker}" \
    --arg zone_id "${zone_id}" \
    --arg zone_name "${zone_name}" \
    '{hostname: $hostname, service: $service, zone_id: $zone_id, zone_name: $zone_name}')"
  api_request PUT "${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" "${body}" >/dev/null
  echo "Worker custom domain attached: ${accounts_host} -> ${core_worker}"
}

reconcile_pages_domain
reconcile_worker_domain
echo "Cloudflare serverless custom domains reconciled for ${zone_name}."
