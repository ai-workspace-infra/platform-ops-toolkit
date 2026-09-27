#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_DNS_API_TOKEN:?CLOUDFLARE_DNS_API_TOKEN is required}"
: "${DNS_ACTION:?DNS_ACTION is required}"
: "${SOURCE_IP:?SOURCE_IP is required}"
readonly API="https://api.cloudflare.com/client/v4"
readonly ZONE="svc.plus"
readonly NAME="observability.svc.plus"
readonly API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN}"

api() {
  local method="$1" url="$2" body="${3:-}" response
  local -a args=(--fail-with-body --silent --show-error --retry 2 --connect-timeout 10 --max-time 30 -X "${method}" \
    -H "Authorization: Bearer ${API_TOKEN}" -H 'Content-Type: application/json')
  [[ -z "${body}" ]] || args+=(--data "${body}")
  response="$(curl "${args[@]}" "${url}")"
  jq -e '.success == true' >/dev/null <<<"${response}" || { jq -c '.errors // .' <<<"${response}" >&2; return 1; }
  printf '%s' "${response}"
}

validate_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
}
validate_ipv4 "${SOURCE_IP}"
case "${DNS_ACTION}" in
  cutover)
    : "${TARGET_IP:?TARGET_IP is required for cutover}"
    validate_ipv4 "${TARGET_IP}"
    [[ "${TARGET_IP}" != "${SOURCE_IP}" ]] || { echo 'Target and source DNS addresses are identical.' >&2; exit 1; }
    desired_ip="${TARGET_IP}"
    expected_ip="${SOURCE_IP}"
    ;;
  rollback)
    desired_ip="${SOURCE_IP}"
    expected_ip="${TARGET_IP:-}"
    ;;
  *) echo "Unsupported DNS_ACTION=${DNS_ACTION}" >&2; exit 2 ;;
esac

zone_response="$(api GET "${API}/zones?name=${ZONE}&status=active")"
zone_id="$(jq -er '.result | if length == 1 then .[0].id else error("expected one active svc.plus zone") end' <<<"${zone_response}")"
record_response="$(api GET "${API}/zones/${zone_id}/dns_records?type=A&name=${NAME}&per_page=100")"
record="$(jq -cer '.result | if length == 1 then .[0] else error("expected exactly one A record for observability.svc.plus") end' <<<"${record_response}")"
current_ip="$(jq -er '.content' <<<"${record}")"
validate_ipv4 "${current_ip}"
record_id="$(jq -er '.id' <<<"${record}")"
if [[ "${DNS_ACTION}" == cutover && "${current_ip}" != "${expected_ip}" ]]; then
  echo "Refusing cutover: current A record is ${current_ip}, expected source ${expected_ip}." >&2
  exit 1
fi
if [[ "${DNS_ACTION}" == rollback ]]; then
  if [[ -n "${expected_ip}" ]]; then
    [[ "${current_ip}" == "${expected_ip}" ]] || { echo "Refusing rollback: current A record is ${current_ip}, expected target ${expected_ip}." >&2; exit 1; }
  else
    [[ "${current_ip}" != "${desired_ip}" ]] || { echo 'DNS is already at the source address.' >&2; exit 1; }
  fi
fi

payload="$(jq -cn --arg type A --arg name "${NAME}" --arg content "${desired_ip}" \
  --arg comment "$(jq -r '.comment // ""' <<<"${record}")" \
  --argjson ttl "$(jq -r '.ttl' <<<"${record}")" \
  --argjson proxied "$(jq -r '.proxied' <<<"${record}")" \
  --argjson tags "$(jq -c '.tags // []' <<<"${record}")" \
  '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied,comment:$comment,tags:$tags}')"
api PUT "${API}/zones/${zone_id}/dns_records/${record_id}" "${payload}" >/dev/null
echo "Updated only ${NAME} A record: ${current_ip} -> ${desired_ip}. Waiting for Cloudflare DNS propagation."

proxied="$(jq -r '.proxied' <<<"${record}")"
propagated=false
for _ in $(seq 1 36); do
  answer="$(curl --fail --silent --show-error --retry 1 -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=${NAME}&type=A" || true)"
  if [[ "${proxied}" == true ]]; then
    if jq -e 'any(.Answer[]?; .type == 1)' >/dev/null <<<"${answer}"; then propagated=true; break; fi
  elif jq -e --arg ip "${desired_ip}" 'any(.Answer[]?; .type == 1 and .data == $ip)' >/dev/null <<<"${answer}"; then
    propagated=true; break
  fi
  sleep 5
done
if [[ "${propagated}" != true ]]; then
  rollback_payload="$(jq -cn --arg type A --arg name "${NAME}" --arg content "${current_ip}" \
    --arg comment "Automatic rollback after observability DNS verification failure" \
    --argjson ttl "$(jq -r '.ttl' <<<"${record}")" --argjson proxied "$(jq -r '.proxied' <<<"${record}")" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied,comment:$comment}')"
  api PUT "${API}/zones/${zone_id}/dns_records/${record_id}" "${rollback_payload}" >/dev/null
  echo "DNS verification failed; restored ${NAME} to ${current_ip}." >&2
  exit 1
fi
updated_record="$(api GET "${API}/zones/${zone_id}/dns_records?type=A&name=${NAME}&per_page=100")"
actual_ip="$(jq -er '.result | if length == 1 then .[0].content else error("expected exactly one A record after update") end' <<<"${updated_record}")"
[[ "${actual_ip}" == "${desired_ip}" ]] || { echo "Cloudflare record verification found ${actual_ip}, expected ${desired_ip}." >&2; exit 1; }
if [[ "${proxied}" == true ]]; then
  echo "Cloudflare record now targets ${desired_ip}; the proxied public DNS answer remains Cloudflare-owned."
else
  echo "Public DNS resolves ${NAME} to ${desired_ip}."
fi
