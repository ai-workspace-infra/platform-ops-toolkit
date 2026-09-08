#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${GITHUB_WORKSPACE:?}"
LAB_DIR="${LAB_DIR:?}"
window="${NODE_OBSERVATION_WINDOW_MINUTES:-0}"
[[ "$window" =~ ^(10|20|until-expiry)$ ]] || { [[ "$window" == 0 ]] && exit 0; echo 'Invalid resolved node observation window' >&2; exit 1; }

handoff="$LAB_DIR/desktop-public/desktop-handoff.json"
test -f "$handoff" || { echo 'Public observation handoff is missing' >&2; exit 1; }
python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-handoff "$handoff"

gateway=$(jq -er '.instances.gateway.public_ip' "$handoff")
gateway_user=$(jq -er '.gateway_ssh_user.value' "$LAB_DIR/outputs.json")
client=$(jq -er '.instances.linux_one.public_ip' "$handoff")
client_user=$(jq -er '.client_ssh_user.value' "$LAB_DIR/outputs.json")
run_id=$(jq -er '.run' "$handoff")
network_id=$(jq -er '.network_id' "$handoff")
gateway_id=$(jq -er '.gateway_id' "$handoff")
client_id="one-${run_id}"
gateway_public_key=$(jq -er '.gateway_public_key' "$handoff")
expires_at=$(jq -er '.expires_at' "$handoff")
lease_expires_at=$(jq -er '.expires_at' "$LAB_DIR/variables.json")
[[ "$expires_at" == "$lease_expires_at" ]] || { echo 'Public handoff expiry does not match the recorded lease expiry' >&2; exit 1; }
lease_deadline=$(python3 - "$expires_at" <<'PY'
from datetime import datetime
import sys
expiry = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')).timestamp()
print(int(expiry))
PY
)
now=$(date +%s)
end="$lease_deadline"
if [[ "$window" != until-expiry ]]; then
  candidate=$((now + window * 60))
  (( candidate < end )) && end="$candidate"
fi

SSH=(-i "$LAB_DIR/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
ssh_with_deadline() {
  local remaining=$((end - $(date +%s)))
  (( remaining > 60 )) && remaining=60
  (( remaining > 0 )) || return 124
  timeout "${remaining}s" ssh "${SSH[@]}" "$@"
}

echo "NODE_OBSERVATION_OPEN run=$run_id minutes=$window lease_expires_at=$expires_at"
if (( end <= now )); then
  echo 'NODE_OBSERVATION_RESULT=UNVERIFIED reason=lease_expired local_independent_acceptance_required=true'
  exit 0
fi

observe_nodes() {
  local gateway_output client_output gateway_refresh=UNVERIFIED client_sync=UNVERIFIED gateway_peer=UNVERIFIED client_peer=UNVERIFIED
  if gateway_output=$(ssh_with_deadline "$gateway_user@$gateway" sudo bash -s -- "$run_id" "$gateway_id" "$network_id" "$client_id" < "$ROOT/.github/scripts/xconnect-lab/remote-gateway-observation.sh" 2>/dev/null); then
    gateway_refresh=$(awk -F= '$1 == "refresh" {print $2}' <<<"$gateway_output" | tail -1)
    gateway_peer=$(awk -F= '$1 == "gateway_peer" {print $2}' <<<"$gateway_output" | tail -1)
  fi
  if client_output=$(ssh_with_deadline "$client_user@$client" sudo bash -s -- "$client_id" "$network_id" "$gateway_public_key" < "$ROOT/.github/scripts/xconnect-lab/remote-client-observation.sh" 2>/dev/null); then
    client_sync=$(awk -F= '$1 == "sync" {print $2}' <<<"$client_output" | tail -1)
    client_peer=$(awk -F= '$1 == "client_peer" {print $2}' <<<"$client_output" | tail -1)
  fi
  echo "NODE_OBSERVATION run=$run_id refresh=${gateway_refresh:-UNVERIFIED} sync=${client_sync:-UNVERIFIED} gateway_peer=${gateway_peer:-UNVERIFIED} client_peer=${client_peer:-UNVERIFIED} SUMMARY_ONLY"
}

while (( $(date +%s) < end )); do
  observe_nodes
  now=$(date +%s)
  remaining=$((end - now))
  (( remaining <= 0 )) && break
  sleep_seconds=30
  (( remaining < sleep_seconds )) && sleep_seconds=$remaining
  sleep "$sleep_seconds"
done
echo 'NODE_OBSERVATION_RESULT=SUMMARY_ONLY local_independent_acceptance_required=true'
