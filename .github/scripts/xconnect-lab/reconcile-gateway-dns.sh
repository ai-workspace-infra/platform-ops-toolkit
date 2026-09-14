#!/usr/bin/env bash
set -euo pipefail

# Reconcile only the stable XConnect Gateway entrypoint. The record must stay
# DNS-only: Cloudflare's HTTP proxy is not a VLESS transport and must not sit
# in front of the Gateway TCP listener.
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${XCONNECT_GATEWAY_DNS_NAME:?XCONNECT_GATEWAY_DNS_NAME is required}"
: "${XCONNECT_GATEWAY_DNS_TARGET:?XCONNECT_GATEWAY_DNS_TARGET is required}"

API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
ZONE_NAME="svc.plus"
TTL="60"

die() {
  echo "::error::$*" >&2
  exit 1
}

[[ "${XCONNECT_GATEWAY_DNS_NAME}" == "tw-xconnect.svc.plus" ]] \
  || die 'XCONNECT_GATEWAY_DNS_NAME must be tw-xconnect.svc.plus for the UAT stable Gateway'

python3 - "${XCONNECT_GATEWAY_DNS_TARGET}" <<'PY' || die 'XCONNECT_GATEWAY_DNS_TARGET must be a public IPv4 address'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if address.version != 4 or address.is_private or address.is_loopback or address.is_reserved:
    raise SystemExit(1)
PY

api_request() {
  local method="$1" url="$2" body="${3:-}" response
  if [[ -n "$body" ]]; then
    response="$(curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
      -X "$method" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data "$body" "$url")" \
      || die "Cloudflare API request failed (${method})"
  else
    response="$(curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
      -X "$method" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      "$url")" \
      || die "Cloudflare API request failed (${method})"
  fi
  jq -e '.success == true' <<<"$response" >/dev/null \
    || die "Cloudflare API rejected the DNS request (${method})"
  printf '%s' "$response"
}

zone_response="$(api_request GET "${API_BASE}/zones?name=${ZONE_NAME}&status=active&account.id=${CLOUDFLARE_ACCOUNT_ID}&per_page=20")"
zone_count="$(jq -r '.result | length' <<<"$zone_response")"
[[ "$zone_count" == 1 ]] || die "Cloudflare zone ${ZONE_NAME} is not uniquely addressable"
zone_id="$(jq -er '.result[0].id' <<<"$zone_response")"

record_url="${API_BASE}/zones/${zone_id}/dns_records?type=A&name=${XCONNECT_GATEWAY_DNS_NAME}&per_page=100"
record_response="$(api_request GET "$record_url")"
record_count="$(jq -r '.result | length' <<<"$record_response")"
[[ "$record_count" -le 1 ]] || die 'Multiple A records exist for tw-xconnect.svc.plus; refusing ambiguous reconciliation'

# Refuse to overwrite a non-A record at the same name. Cloudflare returns only
# A records above, so this second query protects against a conflicting CNAME.
all_records="$(api_request GET "${API_BASE}/zones/${zone_id}/dns_records?name=${XCONNECT_GATEWAY_DNS_NAME}&per_page=100")"
non_a_count="$(jq '[.result[] | select(.type != "A")] | length' <<<"$all_records")"
[[ "$non_a_count" == 0 ]] || die 'A conflicting DNS record exists for tw-xconnect.svc.plus'

body="$(jq -cn \
  --arg name "$XCONNECT_GATEWAY_DNS_NAME" \
  --arg content "$XCONNECT_GATEWAY_DNS_TARGET" \
  --argjson ttl "$TTL" \
  '{type:"A",name:$name,content:$content,ttl:$ttl,proxied:false}')"

if [[ "$record_count" == 1 ]]; then
  record_id="$(jq -er '.result[0].id' <<<"$record_response")"
  api_request PUT "${API_BASE}/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null
else
  api_request POST "${API_BASE}/zones/${zone_id}/dns_records" "$body" >/dev/null
fi

# Wait for public DNS visibility before formal Gateway/One enrollment.
for attempt in $(seq 1 24); do
  resolved="$(dig +short @1.1.1.1 "${XCONNECT_GATEWAY_DNS_NAME}" A 2>/dev/null | sed -n '1p' || true)"
  if [[ "$resolved" == "$XCONNECT_GATEWAY_DNS_TARGET" ]]; then
    echo "Stable XConnect Gateway DNS ready: ${XCONNECT_GATEWAY_DNS_NAME} -> ${resolved} (DNS-only)"
    exit 0
  fi
  sleep 5
done

die 'Cloudflare DNS record was reconciled but is not visible through the public resolver within 120 seconds'
