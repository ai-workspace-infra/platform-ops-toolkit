#!/usr/bin/env bash
set -euo pipefail

# Reconcile the Cloudflare target domains declared by the serverless
# EdgeRoutingConfig. The Frontend Router owns the Console target and the core
# Edge Gateway owns the Accounts target. Pages is an origin behind the router,
# never an owner of the Console custom domain.

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
billing_host="$(jq -er '.spec.serverless.billing_host' "${CONFIG_FILE}")"
billing_upstream="$(jq -er '.spec.serverless.cloud_run.billing_service' "${CONFIG_FILE}")"
frontend_router_worker="$(jq -er '.spec.serverless.frontend_router.worker_name' "${CONFIG_FILE}")"
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

safeguard_pages_domain() {
  local domains_url="${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${pages_project}/domains"
  local domains_response
  local existing_name
  local existing_status
  domains_response="$(api_request GET "${domains_url}" || echo '{"result":[]}')"
  existing_name="$(jq -r --arg hostname "${console_host}" 'first(.result[]? | select(.name == $hostname) | .name) // empty' <<<"${domains_response}")"
  existing_status="$(jq -r --arg hostname "${console_host}" 'first(.result[]? | select(.name == $hostname) | .status // "unknown")' <<<"${domains_response}")"

  if [[ -n "${existing_name}" ]]; then
    echo "Detaching stale Pages domain (${existing_name}, status=${existing_status}) to allow Worker custom domain binding..."
    api_request DELETE "${domains_url}/${existing_name}" >/dev/null || true
  fi
  echo "Pages does not own the Console target: ${console_host}"
}

reconcile_worker_domain() {
  local hostname="$1"
  local service="$2"
  local domains_url="${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains?per_page=100"
  local domains_response
  local existing
  local conflicting_service
  local body
  domains_response="$(api_request GET "${domains_url}")"
  existing="$(jq -r --arg hostname "${hostname}" --arg service "${service}" '
    first(.result[]? | select(.hostname == $hostname and .service == $service) | [.hostname, .service] | @tsv) // empty
  ' <<<"${domains_response}")"
  if [[ -n "${existing}" ]]; then
    echo "Worker custom domain present: ${existing}"
    return
  fi
  conflicting_service="$(jq -r --arg hostname "${hostname}" '
    first(.result[]? | select(.hostname == $hostname) | .service) // empty
  ' <<<"${domains_response}")"
  if [[ -n "${conflicting_service}" ]]; then
    echo "Worker custom domain ${hostname} is already owned by ${conflicting_service}, not ${service}. Resolve the ownership explicitly before rerunning." >&2
    return 1
  fi

  body="$(jq -cn \
    --arg hostname "${hostname}" \
    --arg service "${service}" \
    --arg zone_id "${zone_id}" \
    --arg zone_name "${zone_name}" \
    '{hostname: $hostname, service: $service, zone_id: $zone_id, zone_name: $zone_name}')"
  api_request PUT "${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" "${body}" >/dev/null
  echo "Worker custom domain attached: ${hostname} -> ${service}"
}

reconcile_cname_record() {
  local name="$1"
  local target="$2"
  local records_response
  local primary_id
  records_response="$(api_request GET "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records?name=${name}&type=CNAME&per_page=10")"
  primary_id="$(jq -r '.result[0].id // empty' <<<"${records_response}")"
  local body
  # Every record reconciled here is an HTTPS application entry. Keep it
  # proxied so Cloudflare terminates the public certificate and forwards to
  # the Worker Custom Domain or Cloud Run origin. DNS-only would expose a
  # run.app certificate for Billing and leaves canonical aliases without a
  # routable Cloudflare edge endpoint.
  body="$(jq -cn --arg name "${name}" --arg target "${target}" '{type:"CNAME", name:$name, content:$target, ttl:60, proxied:true}')"
  if [[ -z "${primary_id}" ]]; then
    api_request POST "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records" "${body}" >/dev/null
    echo "Created DNS CNAME: ${name} -> ${target}"
  else
    api_request PUT "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records/${primary_id}" "${body}" >/dev/null
    echo "Updated DNS CNAME: ${name} -> ${target}"
  fi
}

safeguard_pages_domain
reconcile_worker_domain "${console_host}" "${frontend_router_worker}"
reconcile_worker_domain "${accounts_host}" "${core_worker}"
reconcile_cname_record "${billing_host}" "${billing_upstream#https://}"

while IFS=$'\t' read -r record_name record_target; do
  [[ -n "${record_name}" && -n "${record_target}" ]] || continue
  reconcile_cname_record "${record_name}" "${record_target}"
done < <(jq -r '.spec.runtime.routing.dns.canonical_records // {} | to_entries[] | [.key, .value] | @tsv' "${CONFIG_FILE}")

echo "Cloudflare serverless custom domains and DNS reconciled for ${zone_name}."
