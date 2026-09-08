#!/usr/bin/env bash
set -euo pipefail

run_id="$1"
gateway_id="$2"
network_id="$3"
client_id="$4"
state="${XCONNECT_GATEWAY_STATE_DIR:-/var/lib/xconnect-gateway}"
# Observation must not re-apply the WireGuard configuration: `up` tears down
# and recreates the interface, which resets the peer handshake timestamp just
# before we read it. The verify stage already performs the active apply; this
# stage is intentionally read-only and only checks the local state contract.
if ! xconnect-gateway status --state-dir "$state" >/dev/null 2>&1; then
  echo 'refresh=UNVERIFIED'
  exit 0
fi
jq -e --arg gateway "$gateway_id" --arg network "$network_id" \
  '.gateway_id == $gateway and .network_id == $network and .applied_generation > 0 and (.applied_config_id | length) > 0' \
  "$state/state.json" >/dev/null || { echo 'signed_config=UNVERIFIED'; exit 0; }
echo 'refresh=OK'
files=("$state"/runtime/*.conf)
[[ ${#files[@]} -eq 1 && -f "${files[0]}" ]] || { echo 'signed_config=UNVERIFIED'; exit 0; }
device=''
client_key=''
while IFS= read -r line; do
  case "$line" in
    '# DeviceID = '*) device=${line#'# DeviceID = '};;
    'PublicKey = '*)
      if [[ "$device" == "$client_id" ]]; then client_key=${line#'PublicKey = '}; fi
      device=''
      ;;
  esac
done < "${files[0]}"
handshakes=$(wg show xconzero0 latest-handshakes 2>/dev/null || true)
now=$(date +%s)
timestamp=$(awk -v peer="$client_key" '$1 == peer {print $2; exit}' <<<"$handshakes")
if [[ -n "$client_key" && "$timestamp" =~ ^[0-9]+$ ]] && (( timestamp > 0 && now >= timestamp && now - timestamp < 180 )); then
  echo 'gateway_peer=OBSERVED'
else
  echo 'gateway_peer=UNVERIFIED'
fi
