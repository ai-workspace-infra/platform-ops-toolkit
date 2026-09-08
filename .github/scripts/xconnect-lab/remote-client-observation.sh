#!/usr/bin/env bash
set -euo pipefail

client_id="$1"
network_id="$2"
gateway_public_key="$3"
state="${XCONNECT_ONE_STATE_DIR:-/var/lib/xconnect-one}"
if ! xconnect sync --state-dir "$state" >/dev/null 2>&1; then
  echo 'sync=UNVERIFIED'
  exit 0
fi
echo 'sync=OK'
xconnect status --state-dir "$state" | jq -e --arg device "$client_id" --arg network "$network_id" \
  '.joined == true and .device_id == $device and .network_id == $network and .revision != "" and .generations.state > 0 and .runtime.applied == true and .runtime.core_id == "xray" and .credential.present == true and .credential.expired == false' >/dev/null || {
  echo 'signed_config=UNVERIFIED'
  exit 0
}
handshake=$(wg show xconone0 latest-handshakes 2>/dev/null | awk -v peer="$gateway_public_key" '$1 == peer {print $2; exit}')
now=$(date +%s)
if [[ "$handshake" =~ ^[0-9]+$ ]] && (( handshake > 0 && now >= handshake && now - handshake < 180 )); then
  echo 'client_peer=OBSERVED'
else
  echo 'client_peer=UNVERIFIED'
fi
