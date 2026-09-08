#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${GITHUB_WORKSPACE:?}"
LAB_DIR="${LAB_DIR:?}"
window="${DESKTOP_JOIN_WINDOW_MINUTES:-0}"
[[ "$window" =~ ^(10|20)$ ]] || { echo 'desktop_join_window_minutes must be 10 or 20 for the desktop stage' >&2; exit 1; }

handoff="$LAB_DIR/desktop-public/desktop-handoff.json"
test -f "$handoff" || { echo 'Public desktop handoff is missing' >&2; exit 1; }
python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-handoff "$handoff"

gateway=$(jq -er '.instances.gateway.public_ip' "$handoff")
gateway_user=$(jq -er '.gateway_ssh_user.value' "$LAB_DIR/outputs.json")
run_id=$(jq -er '.run' "$handoff")
network_id=$(jq -er '.network_id' "$handoff")
gateway_id=$(jq -er '.gateway_id' "$handoff")
darwin_id=$(jq -er '.expected_device_ids.darwin' "$handoff")
windows_id=$(jq -er '.expected_device_ids.windows' "$handoff")
expires_at=$(jq -er '.expires_at' "$handoff")
lease_deadline=$(python3 - "$expires_at" <<'PY'
from datetime import datetime
import sys
expiry = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')).timestamp()
print(int(expiry) - 600)
PY
)
now=$(date +%s)
end=$((now + window * 60))
(( end > lease_deadline )) && end=$lease_deadline
SSH=(-i "$LAB_DIR/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
ssh_with_deadline() {
  local remaining=$((end - $(date +%s)))
  (( remaining > 60 )) && remaining=60
  (( remaining > 0 )) || return 124
  timeout "${remaining}s" ssh "${SSH[@]}" "$@"
}

echo "DESKTOP_WINDOW_OPEN run=$run_id minutes=$window lease_exit_before=$(date -u -d "@$lease_deadline" +%Y-%m-%dT%H:%M:%SZ)"
if (( end <= now )); then
  echo 'DESKTOP_RESULT=UNVERIFIED reason=lease_exit_deadline_reached local_independent_acceptance_required=true'
  exit 0
fi

probe_gateway() {
  local output refresh=UNVERIFIED darwin=UNVERIFIED windows=UNVERIFIED
  if output=$(ssh_with_deadline "$gateway_user@$gateway" sudo bash -s -- "$run_id" "$gateway_id" "$network_id" "$darwin_id" "$windows_id" <<'GATEWAY_DESKTOP' 2>/dev/null
set -euo pipefail
run_id="$1"
gateway_id="$2"
network_id="$3"
darwin_id="$4"
windows_id="$5"
state=/var/lib/xconnect-gateway
if ! xconnect-gateway up --state-dir "$state" >/dev/null 2>&1; then
  echo 'refresh=UNVERIFIED'
  exit 0
fi
jq -e --arg gateway "$gateway_id" --arg network "$network_id" \
  '.gateway_id == $gateway and .network_id == $network and .applied_generation > 0 and (.applied_config_id | length) > 0' \
  "$state/state.json" >/dev/null || { echo 'signed_config=UNVERIFIED'; exit 0; }
echo 'refresh=OK'
files=("$state"/runtime/*.conf)
[[ ${#files[@]} -eq 1 && -f "${files[0]}" ]] || { echo 'signed_config=UNVERIFIED'; exit 0; }
declare -A keys=()
device=''
while IFS= read -r line; do
  case "$line" in
    '# DeviceID = '*) device=${line#'# DeviceID = '};;
    'PublicKey = '*) [[ -n "$device" ]] && keys["$device"]=${line#'PublicKey = '}; device='';;
  esac
done < "${files[0]}"
handshakes=$(wg show xconzero0 latest-handshakes 2>/dev/null || true)
check_peer() {
  local id="$1" key timestamp now
  key="${keys[$id]-}"
  [[ -n "$key" ]] || { echo "$id=UNVERIFIED"; return; }
  now=$(date +%s)
  timestamp=$(awk -v peer="$key" '$1 == peer {print $2; exit}' <<<"$handshakes")
  if [[ "$timestamp" =~ ^[0-9]+$ ]] && (( timestamp > 0 && now >= timestamp && now - timestamp < 180 )); then
    echo "$id=OBSERVED"
  else
    echo "$id=UNVERIFIED"
  fi
}
check_peer "$darwin_id"
check_peer "$windows_id"
GATEWAY_DESKTOP
  ); then
    refresh=$(awk -F= '$1 == "refresh" {print $2}' <<<"$output" | tail -1)
    darwin=$(awk -F= -v id="$darwin_id" '$1 == id {print $2}' <<<"$output" | tail -1)
    windows=$(awk -F= -v id="$windows_id" '$1 == id {print $2}' <<<"$output" | tail -1)
  fi
  echo "DESKTOP_OBSERVATION run=$run_id refresh=${refresh:-UNVERIFIED} darwin=${darwin:-UNVERIFIED} windows=${windows:-UNVERIFIED}"
}

while (( $(date +%s) < end )); do
  probe_gateway
  now=$(date +%s)
  remaining=$((end - now))
  (( remaining <= 0 )) && break
  sleep_seconds=30
  (( remaining < sleep_seconds )) && sleep_seconds=$remaining
  sleep "$sleep_seconds"
done
echo 'DESKTOP_RESULT=UNVERIFIED peer-handshake-observation-only=true local_ping_http_acceptance_required=true local_independent_acceptance_required=true'
