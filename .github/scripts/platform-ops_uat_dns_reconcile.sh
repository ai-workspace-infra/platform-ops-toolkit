#!/usr/bin/env bash
set -euo pipefail

# This is intentionally a separate reconciler from the disaster-recovery DNS
# cutover. It remains UAT-only, while the zone and record names are rendered
# from the resolved deployment parameters.
readonly CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE_OVERRIDE:-https://api.cloudflare.com/client/v4}"

: "${CLOUDFLARE_DNS_API_TOKEN:?CLOUDFLARE_DNS_API_TOKEN is required}"
if [[ "${DEPLOY_ENV:-}" != "uat" ]]; then
  echo "::error::UAT DNS reconciler requires DEPLOY_ENV=uat." >&2
  exit 1
fi
if [[ -z "${TARGET_DOMAIN_BASE:-}" || "${TARGET_DOMAIN_BASE}" == "${SOURCE_DOMAIN_BASE:-}" || "${TARGET_DOMAIN_BASE}" == *[!a-zA-Z0-9.-]* ]]; then
  echo "::error::UAT DNS reconciler requires a valid target zone distinct from the source zone." >&2
  exit 1
fi
readonly UAT_ZONE="${TARGET_DOMAIN_BASE}"
cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"

command -v curl >/dev/null || { echo "::error::curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "::error::jq is required" >&2; exit 1; }

if [[ ! -f "${cmdb_file}" ]]; then
  echo "::error::CMDB file not found: ${cmdb_file}" >&2
  exit 1
fi

mapfile -t web_saas_hosts < <(
  jq -r 'to_entries[] | select((.value.groups // []) | index("web_saas")) | .key' "${cmdb_file}"
)
if [[ "${#web_saas_hosts[@]}" -ne 1 ]]; then
  echo "::error::UAT DNS requires exactly one web_saas host in ${cmdb_file}; found ${#web_saas_hosts[@]}." >&2
  exit 1
fi

web_saas_ip="$(jq -er --arg host "${web_saas_hosts[0]}" '.[$host].ip // empty' "${cmdb_file}")"
if [[ ! "${web_saas_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! jq -n -e --arg ip "${web_saas_ip}" '
  ($ip | split(".")) as $octets
  | ($octets | length == 4)
  and all($octets[]; (tonumber >= 0 and tonumber <= 255))
' >/dev/null; then
  echo "::error::CMDB web_saas host has an invalid IPv4 address: ${web_saas_ip}" >&2
  exit 1
fi

# agent-proxy is a separate native host. Only render its record when this
# delivery produced exactly one such host; never point it at the Web SaaS IP.
mapfile -t agent_proxy_hosts < <(
  jq -r 'to_entries[] | select((.value.groups // []) | index("agent_proxy")) | .key' "${cmdb_file}"
)
if [[ "${#agent_proxy_hosts[@]}" -gt 1 ]]; then
  echo "::error::UAT DNS requires at most one agent_proxy host in ${cmdb_file}; found ${#agent_proxy_hosts[@]}." >&2
  exit 1
fi

agent_proxy_ip=""
if [[ "${#agent_proxy_hosts[@]}" -eq 1 ]]; then
  agent_proxy_ip="$(jq -er --arg host "${agent_proxy_hosts[0]}" '.[$host].ip // empty' "${cmdb_file}")"
  if [[ ! "${agent_proxy_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! jq -n -e --arg ip "${agent_proxy_ip}" '
    ($ip | split(".")) as $octets
    | ($octets | length == 4)
    and all($octets[]; (tonumber >= 0 and tonumber <= 255))
  ' >/dev/null; then
    echo "::error::CMDB agent_proxy host has an invalid IPv4 address: ${agent_proxy_ip}" >&2
    exit 1
  fi
fi

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
    --header "Authorization: Bearer ${CLOUDFLARE_DNS_API_TOKEN}"
    --header "Content-Type: application/json"
  )

  if [[ -n "${body}" ]]; then
    curl_args+=(--data "${body}")
  fi

  if ! response="$(curl "${curl_args[@]}" "${url}")"; then
    echo "::error::Cloudflare API request failed: ${method} ${url}" >&2
    return 1
  fi
  if ! jq -e '.success == true' >/dev/null <<<"${response}"; then
    echo "::error::Cloudflare API returned success=false: ${method} ${url}" >&2
    jq -c '.errors // .messages // []' <<<"${response}" >&2 || true
    return 1
  fi
  printf '%s' "${response}"
}

delete_record() {
  local zone_id="$1"
  local record_id="$2"
  api_request DELETE "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records/${record_id}" >/dev/null
}

zone_response="$(api_request GET "${CLOUDFLARE_API_BASE}/zones?name=${UAT_ZONE}&status=active")"
zone_id="$(jq -er '
  .result
  | if length == 1 then .[0].id else error("expected exactly one active UAT zone") end
' <<<"${zone_response}")"

desired_payload() {
  local record_name="$1"
  local record_ip="$2"
  jq -cn \
    --arg name "${record_name}" \
    --arg ip "${record_ip}" \
    '{type:"A", name:$name, content:$ip, ttl:1, proxied:false}'
}

reconcile_record() {
  local record_name="$1"
  local record_ip="$2"
  records_response="$(api_request GET "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records?name=${record_name}&per_page=100")"
  primary_id="$(jq -r '.result | map(select(.type == "A")) | .[0].id // empty' <<<"${records_response}")"

  if [[ -z "${primary_id}" ]]; then
    while IFS= read -r record_id; do
      [[ -z "${record_id}" ]] || delete_record "${zone_id}" "${record_id}"
    done < <(jq -r '.result[].id' <<<"${records_response}")
    api_request POST "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records" "$(desired_payload "${record_name}" "${record_ip}")" >/dev/null
    echo "Created ${record_name} -> ${record_ip}"
    return
  fi

  current_primary="$(jq -c --arg id "${primary_id}" '.result[] | select(.id == $id)' <<<"${records_response}")"
  if ! jq -e --arg name "${record_name}" --arg ip "${record_ip}" '
    .type == "A"
    and .name == $name
    and .content == $ip
    and (.ttl | tonumber) == 1
    and .proxied == false
  ' >/dev/null <<<"${current_primary}"; then
    api_request PUT "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records/${primary_id}" "$(desired_payload "${record_name}" "${record_ip}")" >/dev/null
    echo "Updated ${record_name} -> ${record_ip}"
  else
    echo "Unchanged ${record_name} -> ${record_ip}"
  fi

  while IFS= read -r record_id; do
    [[ -z "${record_id}" ]] || delete_record "${zone_id}" "${record_id}"
  done < <(jq -r --arg primary_id "${primary_id}" '.result[] | select(.id != $primary_id) | .id' <<<"${records_response}")
}

reconcile_record "billing-${DEPLOY_ENV}.${TARGET_DOMAIN_BASE}" "${web_saas_ip}"
reconcile_record "console-${DEPLOY_ENV}.${TARGET_DOMAIN_BASE}" "${web_saas_ip}"
reconcile_record "accounts-${DEPLOY_ENV}.${TARGET_DOMAIN_BASE}" "${web_saas_ip}"
if [[ -n "${agent_proxy_ip}" ]]; then
  reconcile_record "agent-proxy.${TARGET_DOMAIN_BASE}" "${agent_proxy_ip}"
fi

record_count=3
if [[ -n "${agent_proxy_ip}" ]]; then
  record_count=4
fi
echo "UAT DNS reconciliation completed for ${record_count} rendered records in ${UAT_ZONE}; web-saas ${web_saas_hosts[0]} (${web_saas_ip})${agent_proxy_ip:+, agent-proxy ${agent_proxy_hosts[0]} (${agent_proxy_ip})}."
