#!/usr/bin/env bash
set -euo pipefail

# Reconcile the Cloudflare target domains declared by the serverless
# EdgeRoutingConfig. Frontend Router owns Console and the core Edge Gateway
# owns Accounts. The core Edge Gateway also owns Billing and proxies it to
# Cloud Run. Cloudflare Origin Rules cannot override Host/SNI on non-Enterprise
# plans, so this workflow must not depend on a zone Ruleset for Billing.
# Canonical Console/Accounts aliases are changed only during an explicit
# serverless cutover. A normal deployment must not take ownership of the
# shared canonical records from selfhost.

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps manifest}"
CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE_OVERRIDE:-https://api.cloudflare.com/client/v4}"
serverless_dns_mode="${SERVERLESS_DNS_MODE:-none}"

case "${serverless_dns_mode}" in
  none|uat-records|prod-cutover)
    ;;
  *)
    echo "SERVERLESS_DNS_MODE must be one of: none, uat-records, prod-cutover" >&2
    exit 2
    ;;
esac

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
billing_origin_host="$(jq -r '.spec.serverless.billing_origin_host // empty' "${CONFIG_FILE}")"
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
    if [[ -n "${response:-}" ]]; then
      echo "Cloudflare API error body:" >&2
      jq -c '.' <<<"${response}" >&2 || printf '%s\n' "${response}" >&2
    fi
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

remove_worker_routes_for_host() {
  local hostname="$1"
  local expected_service="${2:-}"
  local routes_url="${CLOUDFLARE_API_BASE}/zones/${zone_id}/workers/routes"
  local routes_response
  local route_id
  local pattern
  local pattern_host
  local route_service

  routes_response="$(api_request GET "${routes_url}")"
  while IFS=$'\t' read -r route_id pattern route_service; do
    [[ -n "${route_id}" && -n "${pattern}" ]] || continue
    pattern_host="${pattern#*://}"
    pattern_host="${pattern_host%%/*}"
    pattern_host="${pattern_host%%:*}"
    if [[ "${pattern_host}" != "${hostname}" ]]; then
      continue
    fi
    if [[ -n "${expected_service}" && "${route_service}" != "${expected_service}" ]]; then
      continue
    fi
    api_request DELETE "${routes_url}/${route_id}" >/dev/null
    echo "Removed stale Worker Route: ${pattern}"
  done < <(jq -r '.result[]? | [.id, .pattern, (.script // empty)] | @tsv' <<<"${routes_response}")
}

detach_worker_domain() {
  local hostname="$1"
  local expected_service="$2"
  local domains_url="${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains?per_page=100"
  local domains_response
  domains_response="$(api_request GET "${domains_url}")"

  while IFS=$'\t' read -r domain_id domain_service; do
    [[ -n "${domain_id}" ]] || continue
    if [[ "${domain_service}" != "${expected_service}" ]]; then
      echo "Worker custom domain ${hostname} is owned by ${domain_service}, not ${expected_service}; refusing to detach it." >&2
      return 1
    fi
    api_request DELETE "${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/${domain_id}" >/dev/null
    echo "Detached Worker custom domain: ${hostname} -> ${domain_service}"
  done < <(jq -r --arg hostname "${hostname}" '.result[]? | select(.hostname == $hostname) | [.id, .service] | @tsv' <<<"${domains_response}")
}

remove_declared_cname() {
  local name="$1"
  local expected_target="${2:-}"
  local records_response
  records_response="$(api_request GET "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records?name=${name}&type=CNAME&per_page=100")"

  while IFS=$'\t' read -r record_id record_target; do
    [[ -n "${record_id}" ]] || continue
    if [[ -n "${expected_target}" && "${record_target%.}" != "${expected_target%.}" ]]; then
      echo "DNS CNAME ${name} points to unexpected target ${record_target}; refusing to delete it before Worker binding." >&2
      return 1
    fi
    api_request DELETE "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records/${record_id}" >/dev/null
    echo "Removed conflicting DNS CNAME: ${name} -> ${record_target}"
  done < <(jq -r '.result[]? | [.id, .content] | @tsv' <<<"${records_response}")
}

reconcile_cname_record() {
  local name="$1"
  local target="$2"
  local proxied="${3:-true}"
  local records_response
  local primary_id
  records_response="$(api_request GET "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records?name=${name}&type=CNAME&per_page=10")"
  primary_id="$(jq -r '.result[0].id // empty' <<<"${records_response}")"
  local body
  # Public entries stay proxied; the Billing origin alias must remain DNS-only
  # so the Origin Rule cannot recurse through Cloudflare.
  body="$(jq -cn --arg name "${name}" --arg target "${target}" --argjson proxied "${proxied}" '{type:"CNAME", name:$name, content:$target, ttl:60, proxied:$proxied}')"
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
# A Worker custom domain is the only supported owner for Console. Explicit
# Worker Routes take precedence over it and can bypass Frontend Router, so
# remove every route on the GitOps-declared Console host.
remove_worker_routes_for_host "${console_host}"
reconcile_worker_domain "${accounts_host}" "${core_worker}"
remove_declared_cname "${billing_host}" "${billing_upstream#https://}"
reconcile_worker_domain "${billing_host}" "${core_worker}"
# Remove the DNS-only alias left by the retired Enterprise-only Origin Rule
# design. It is not part of the public service contract.
if [[ -n "${billing_origin_host}" ]]; then
  remove_declared_cname "${billing_origin_host}" "${billing_upstream#https://}"
fi

if [[ "${serverless_dns_mode}" != "none" ]]; then
  while IFS=$'\t' read -r record_name record_target; do
    [[ -n "${record_name}" && -n "${record_target}" ]] || continue
    case "${record_target%.}" in
      "${console_host%.}")
        # Bind the canonical hostname before removing the old self-host CNAME.
        # This makes the explicit UAT cutover safe: the legacy record is only
        # removed after Worker custom-domain ownership is confirmed or created.
        reconcile_worker_domain "${record_name}" "${frontend_router_worker}"
        remove_declared_cname "${record_name}" "${record_target}"
        ;;
      "${accounts_host%.}")
        detach_worker_domain "${record_name}" "${core_worker}"
        reconcile_cname_record "${record_name}" "${record_target}"
        ;;
      *)
        reconcile_cname_record "${record_name}" "${record_target}"
        ;;
    esac
  done < <(jq -r '.spec.runtime.routing.dns.canonical_records // {} | to_entries[] | [.key, .value] | @tsv' "${CONFIG_FILE}")
else
  while IFS=$'\t' read -r record_name record_target; do
    [[ "${record_target%.}" == "${accounts_host%.}" ]] || continue
    # Edge Gateway deployment may declare canonical API routes for explicit
    # cutovers. A normal dns_mode=none run must remove only its own legacy
    # route and leave unrelated scripts untouched.
    remove_worker_routes_for_host "${record_name}" "${core_worker}"
  done < <(jq -r '.spec.runtime.routing.dns.canonical_records // {} | to_entries[] | [.key, .value] | @tsv' "${CONFIG_FILE}")
  echo "Skipping canonical DNS reconciliation; SERVERLESS_DNS_MODE=none leaves shared records under the current owner."
fi

echo "Cloudflare serverless mode domains and DNS reconciled for ${zone_name} (dns_mode=${serverless_dns_mode})."
