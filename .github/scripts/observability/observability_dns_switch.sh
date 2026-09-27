#!/usr/bin/env bash
set -euo pipefail
trap 'status=$?; echo "::error::Observability DNS script failed at line ${LINENO} (exit ${status})." >&2; exit "${status}"' ERR

: "${CLOUDFLARE_DNS_API_TOKEN:?CLOUDFLARE_DNS_API_TOKEN is required}"
: "${DNS_ACTION:?DNS_ACTION is required}"
: "${SOURCE_IP:?SOURCE_IP is required}"
: "${SSH_PRIVATE_KEY_PATH:?SSH_PRIVATE_KEY_PATH is required}"
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
wait_for_dns() {
  local expected_ip="$1" attempt resolver answer converged
  for attempt in $(seq 1 30); do
    converged=true
    for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
      answer="$(dig +short @"${resolver}" "${NAME}" A | sort -u)"
      if ! grep -Fxq "${expected_ip}" <<<"${answer}"; then converged=false; fi
      printf 'resolver=%s attempt=%s records=%s\n' "${resolver}" "${attempt}" "${answer:-none}"
    done
    [[ "${converged}" == true ]] && return 0
    sleep 10
  done
  return 1
}
restore_dns() {
  local reason="$1" restore_payload
  restore_payload="$(jq -cn --arg type A --arg name "${NAME}" --arg content "${current_ip}" \
    --arg comment "Automatic rollback after observability ${reason} failure" \
    --argjson ttl "${original_ttl}" --argjson proxied "${original_proxied}" \
    --argjson tags "$(jq -c '.tags // []' <<<"${record}")" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied,comment:$comment,tags:$tags}')"
  api PUT "${API}/zones/${zone_id}/dns_records/${record_id}" "${restore_payload}" >/dev/null
  if [[ "${original_proxied}" == false ]] && ! wait_for_dns "${current_ip}"; then
    echo "DNS ${reason} failed; Cloudflare restored ${NAME} to ${current_ip}, but public resolver propagation remains pending." >&2
  else
    echo "DNS ${reason} failed; restored ${NAME} to ${current_ip}." >&2
  fi
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
original_ttl="$(jq -er '.ttl' <<<"${record}")"
original_proxied="$(jq -er '.proxied' <<<"${record}")"
echo "Resolved one ${NAME} A record: current=${current_ip}, ttl=${original_ttl}, proxied=${original_proxied}."
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
  --argjson ttl 60 \
  --argjson proxied false \
  --argjson tags "$(jq -c '.tags // []' <<<"${record}")" \
  '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied,comment:$comment,tags:$tags}')"
echo "Requesting ${DNS_ACTION}: ${current_ip} -> ${desired_ip}, TTL 60, DNS-only."
api PUT "${API}/zones/${zone_id}/dns_records/${record_id}" "${payload}" >/dev/null
echo "Updated only ${NAME} A record: ${current_ip} -> ${desired_ip}. Waiting for Cloudflare DNS propagation."

if ! wait_for_dns "${desired_ip}"; then
  if [[ "${DNS_ACTION}" == cutover ]]; then
    restore_dns DNS
  else
    echo "DNS rollback was written to Cloudflare, but resolver propagation is still pending." >&2
  fi
  exit 1
fi
updated_record="$(api GET "${API}/zones/${zone_id}/dns_records?type=A&name=${NAME}&per_page=100")"
actual_ip="$(jq -er '.result | if length == 1 then .[0].content else error("expected exactly one A record after update") end' <<<"${updated_record}")"
[[ "${actual_ip}" == "${desired_ip}" ]] || { echo "Cloudflare record verification found ${actual_ip}, expected ${desired_ip}." >&2; exit 1; }
actual_proxied="$(jq -er '.result | if length == 1 then .[0].proxied else error("expected exactly one A record after update") end' <<<"${updated_record}")"
[[ "${actual_proxied}" == false ]] || { echo "Cloudflare record ${NAME} must be DNS-only for direct origin validation." >&2; exit 1; }
if [[ "${DNS_ACTION}" == cutover ]]; then
  if ! ssh -i "${SSH_PRIVATE_KEY_PATH}" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
    "root@${TARGET_IP}" 'systemctl restart caddy'; then
    restore_dns Caddy
    exit 1
  fi
  healthy=false
  for _ in $(seq 1 36); do
    code="$(curl --connect-timeout 5 --max-time 10 --silent --show-error --output /dev/null \
      --write-out '%{http_code}' --resolve "${NAME}:443:${desired_ip}" "https://${NAME}/grafana/api/health" 2>/dev/null || true)"
    if [[ "${code}" == 200 ]]; then healthy=true; break; fi
    sleep 5
  done
  if [[ "${healthy}" != true ]]; then
    restore_dns HTTPS
    exit 1
  fi
  echo "Verified public TLS and Grafana API health on ${NAME} at ${desired_ip}."
fi
echo "Public DNS resolves ${NAME} to ${desired_ip} via 1.1.1.1, 8.8.8.8, and 9.9.9.9."
