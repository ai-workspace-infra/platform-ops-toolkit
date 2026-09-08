#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${GITHUB_WORKSPACE:?}"
LAB_DIR="${LAB_DIR:?}"
DECL="$ROOT/gitops/vpn-overlay/uat/xconnect-lab.json"
gateway=$(jq -er .gateway_ip.value "$LAB_DIR/outputs.json")
gateway_transport=$(jq -er .gateway_transport_ip.value "$LAB_DIR/outputs.json")
gateway_user=$(jq -er .gateway_ssh_user.value "$LAB_DIR/outputs.json")
client=$(jq -er .client_ip.value "$LAB_DIR/outputs.json")
client_user=$(jq -er .client_ssh_user.value "$LAB_DIR/outputs.json")
formal_zero=$(jq -er .zero_accounts_api_url.value "$LAB_DIR/outputs.json")
formal_portal=$(jq -er .zero_portal_url.value "$LAB_DIR/outputs.json")
base_network_id=$(jq -er .spec.overlay.network_id "$DECL")
gateway_address=$(jq -er .spec.overlay.gateway_address "$DECL")
run_id=$(<"$LAB_DIR/run-id")
network_id="${base_network_id}-${run_id}"
gateway_id="gw-${run_id}"
client_id="one-${run_id}"
SSH=(-i "$LAB_DIR/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")

wait_for_ssh() {
  local user="$1" host="$2" ready=false
  for attempt in {1..60}; do
    if ssh "${SSH[@]}" "$user@$host" true 2>/dev/null; then ready=true; break; fi
    sleep 5
  done
  "$ready" || { echo "SSH bootstrap unavailable for $user@$host"; exit 1; }
  ssh "${SSH[@]}" "$user@$host" 'sudo cloud-init status --wait >/dev/null 2>&1; sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools curl ca-certificates python3 openssl iproute2 jq >/dev/null 2>&1'
}

prepare_runtime() {
wait_for_ssh "$gateway_user" "$gateway"
wait_for_ssh "$client_user" "$client"

mkdir -p "$LAB_DIR/tls" "$LAB_DIR/invites"
openssl req -x509 -newkey rsa:3072 -nodes -days 1 -subj '/CN=XConnect disposable UAT lab CA' -keyout "$LAB_DIR/tls/ca.key" -out "$LAB_DIR/tls/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:3072 -nodes -subj '/CN=xconnect-lab.invalid' -keyout "$LAB_DIR/tls/server.key" -out "$LAB_DIR/tls/server.csr" >/dev/null 2>&1
{
  printf 'subjectAltName=DNS:xconnect-lab.invalid,IP:%s\n' "$gateway_transport"
  printf 'extendedKeyUsage=serverAuth\n'
} > "$LAB_DIR/tls/extensions"
openssl x509 -req -in "$LAB_DIR/tls/server.csr" -CA "$LAB_DIR/tls/ca.crt" -CAkey "$LAB_DIR/tls/ca.key" -CAcreateserial -days 1 -extfile "$LAB_DIR/tls/extensions" -out "$LAB_DIR/tls/server.crt" >/dev/null 2>&1

echo 'Stage: formal Zero readiness'
status=$(curl --silent --show-error --output "$LAB_DIR/zero-readiness.json" --write-out '%{http_code}' \
  -H "X-Service-Token: $ZERO_SERVICE_TOKEN" -H 'Content-Type: application/json' \
  --data-binary '{}' "$formal_zero/api/internal/overlay/networks/bootstrap" || true)
[[ "$status" == 400 ]] || { echo "Formal Zero bootstrap endpoint is unavailable: HTTP $status"; exit 1; }
curl --fail --silent --show-error --output /dev/null "${formal_portal%/panel/xconnect-zero}/panel/xconnect-zero"

echo 'Stage: Gateway runtime bootstrap'
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect-gateway" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/server.key" "$LAB_DIR/tls/server.crt" "$LAB_DIR/tls/ca.crt" "$ROOT/.github/scripts/xconnect-lab/gateway.sh" "$gateway_user@$gateway:/tmp/" >/dev/null
ssh "${SSH[@]}" "$gateway_user@$gateway" "sudo bash /tmp/gateway.sh '$gateway_transport' '$run_id' '$formal_zero' '$formal_portal' '$network_id' '$gateway_id'"
gateway_public_key=$(ssh "${SSH[@]}" "$gateway_user@$gateway" 'sudo cat /opt/xconnect-lab/gateway.pub')
[[ "$gateway_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'Gateway returned an invalid WireGuard public key'; exit 1; }
printf '%s\n' "$gateway_public_key" > "$LAB_DIR/gateway-public-key"
}

create_invite() {
  local role="$1" device_id="$2" destination="$3"
  local response="$LAB_DIR/invites/${role}-response.json"
  local request="$LAB_DIR/invites/${role}-request.json"
  local expires
  expires=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(minutes=45)).isoformat(timespec="seconds").replace("+00:00","Z"))')
  jq -n \
    --arg owner "$ZERO_OWNER_EMAIL" --arg controller "$formal_zero" \
    --arg network "$network_id" --arg gateway_id "$gateway_id" --arg gateway_key "$gateway_public_key" \
    --arg endpoint "$gateway_transport" --arg gateway_address "$gateway_address" --arg vless "$LAB_VLESS_ID" \
    --arg role "$role" --arg device "$device_id" --arg expires "$expires" \
    '{owner_email:$owner,bootstrap:{controller_url:$controller,network:{id:$network,display_name:"XConnect UAT disposable lab",cidr:"10.77.0.0/24",gateway_id:$gateway_id,gateway_wireguard_public_key:$gateway_key,gateway_wireguard_address:$gateway_address,gateway_endpoint_host:$endpoint,gateway_endpoint_port:51820,transport_server_name:"xconnect-lab.invalid",transport_port:443,transport_auth_id:$vless},invite:{device_id:$device,platform:"linux",role:$role,expires_at:$expires}}}' > "$request"
  status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    -H "X-Service-Token: $ZERO_SERVICE_TOKEN" -H 'Content-Type: application/json' \
    --data-binary "@$request" "$formal_zero/api/internal/overlay/networks/bootstrap" || true)
  [[ "$status" == 201 ]] || { echo "Formal Zero failed to create $role invite: HTTP $status"; exit 1; }
  jq -e --arg network "$network_id" --arg device "$device_id" --arg role "$role" \
    '.network.id == $network and .invite.network_id == $network and .invite.device_id == $device and .invite.role == $role and .invite.platform == "linux" and .invite.remaining_uses == 1' \
    "$response" >/dev/null || { echo 'Formal invitation identity binding mismatch'; exit 1; }
  jq -er .join_uri "$response" > "$destination"
  chmod 600 "$destination"
}

bootstrap_accounts() {
gateway_public_key=$(<"$LAB_DIR/gateway-public-key")
echo 'Stage: real Accounts network and device-bound invitations'
create_invite gateway "$gateway_id" "$LAB_DIR/invites/gateway"
create_invite one "$client_id" "$LAB_DIR/invites/one"
}

enroll_gateway() {
echo 'Stage: formal Gateway enrollment and apply'
scp "${SSH[@]}" "$LAB_DIR/invites/gateway" "$gateway_user@$gateway:/tmp/gateway-invite" >/dev/null
ssh "${SSH[@]}" "$gateway_user@$gateway" "set -eu; sudo install -m 600 /tmp/gateway-invite /opt/xconnect-lab/gateway-invite; sudo sh -c 'xconnect-gateway join --state-dir /var/lib/xconnect-gateway --gateway-id \"$gateway_id\" \"\$(cat /opt/xconnect-lab/gateway-invite)\"'; sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway; sudo systemctl enable --now xconnect-gateway-sync.timer xconnect-lab-http.service"
}

enroll_one() {
echo 'Stage: controlled-client formal enrollment and apply'
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/ca.crt" "$LAB_DIR/invites/one" "$client_user@$client:/tmp/" >/dev/null
ssh "${SSH[@]}" "$client_user@$client" "set -eu; sudo install -m 755 /tmp/xconnect /tmp/xray /usr/local/bin/; sudo install -m 644 /tmp/ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt; sudo update-ca-certificates >/dev/null 2>&1; sudo install -d -m 700 /var/lib/xconnect-one /etc/xconnect-lab; sudo install -m 600 /tmp/one /var/lib/xconnect-one/join-uri; printf '%s\n' controlled-client | sudo tee /etc/xconnect-lab/node-role >/dev/null; sudo sh -c 'xconnect join --state-dir /var/lib/xconnect-one --device-id \"$client_id\" --name uat-linux-one \"\$(cat /var/lib/xconnect-one/join-uri)\"'"
# `join` applies the runtime as part of enrollment. A second, idempotent `up`
# makes the deployment contract explicit and repairs a runtime that stopped
# between enrollment and verification.
ssh "${SSH[@]}" "$client_user@$client" 'sudo xconnect up --state-dir /var/lib/xconnect-one'

# One enrollment advances the centralized generation. Reconcile the Gateway so
# its WireGuard peer set contains the newly registered controlled client.
ssh "${SSH[@]}" "$gateway_user@$gateway" 'sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway'
}

verify_overlay() {
echo 'Stage: formal control plane and two-node data-plane verification'
gateway_public_key=$(<"$LAB_DIR/gateway-public-key")
if ! client_public_key=$(ssh "${SSH[@]}" "$client_user@$client" 'sudo wg show xconone0 public-key'); then
  echo 'Linux One verification failed: xconone0/public-key is unavailable; collecting safe runtime diagnostics.'
  ssh "${SSH[@]}" "$client_user@$client" sudo bash -s <<'CLIENT_EARLY_FAILURE_DIAGNOSTICS' || true
set -euo pipefail
if ip link show xconone0 >/dev/null 2>&1; then echo 'wireguard_interface=active'; else echo 'wireguard_interface=inactive'; fi
if pgrep -x xray >/dev/null; then echo 'xray_process=active'; else echo 'xray_process=inactive'; fi
if ss -lun | grep -Eq '127\.0\.0\.1:18080[[:space:]]'; then echo 'xray_loopback_udp=active'; else echo 'xray_loopback_udp=inactive'; fi
sudo xconnect status --state-dir /var/lib/xconnect-one 2>/dev/null | jq -c '{joined,device_id,network_id,generations,runtime,credential: {present: .credential.present, expired: .credential.expired}}' || true
sudo xconnect diagnose --state-dir /var/lib/xconnect-one 2>/dev/null | jq -c '[.[] | {code,healthy}]' || true
CLIENT_EARLY_FAILURE_DIAGNOSTICS
  exit 1
fi
[[ "$client_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'One returned an invalid WireGuard public key'; exit 1; }
if ! ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$run_id" <<'GATEWAY_VERIFY'
set -euo pipefail
[[ "$(cat /etc/xconnect-lab/node-role)" == relay ]]
[[ "$(cat /etc/xconnect-lab/lab-run)" == "$1" ]]
systemctl is-active --quiet xconnect-gateway-xray.service
systemctl is-active --quiet xconnect-lab-http.service
wg show xconzero0 >/dev/null
ss -ltn | grep -Eq ':443[[:space:]]'
xconnect-gateway status --state-dir /var/lib/xconnect-gateway
GATEWAY_VERIFY
then
  echo 'Gateway verification failed; collecting public runtime health only.'
  ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s <<'GATEWAY_EARLY_FAILURE_DIAGNOSTICS' || true
set -euo pipefail
if systemctl is-active --quiet xconnect-gateway-xray.service; then echo 'gateway_xray_process=active'; else echo 'gateway_xray_process=inactive'; fi
if systemctl is-active --quiet xconnect-lab-http.service; then echo 'gateway_http_service=active'; else echo 'gateway_http_service=inactive'; fi
if ss -ltn | grep -Eq ':443[[:space:]]'; then echo 'gateway_xray_listener=active'; else echo 'gateway_xray_listener=inactive'; fi
if ip link show xconzero0 >/dev/null 2>&1; then echo 'gateway_wireguard_interface=active'; else echo 'gateway_wireguard_interface=inactive'; fi
GATEWAY_EARLY_FAILURE_DIAGNOSTICS
  exit 1
fi

if ! ssh "${SSH[@]}" "$client_user@$client" sudo bash -s -- "$run_id" "$gateway_transport" "$gateway_public_key" "$client_id" "$network_id" <<'CLIENT_VERIFY'
set -euo pipefail
client_failure() {
  echo "Client verification failed: $1"
  xconnect diagnose --state-dir /var/lib/xconnect-one 2>/dev/null \
    | jq -c '[.[] | {code,healthy}]' || true
  if pgrep -x xray >/dev/null; then echo 'xray_process=active'; else echo 'xray_process=inactive'; fi
  if ss -lun | grep -Eq '127\.0\.0\.1:18080[[:space:]]'; then echo 'xray_loopback_udp=active'; else echo 'xray_loopback_udp=inactive'; fi
  if ip link show xconone0 >/dev/null 2>&1; then echo 'wireguard_interface=active'; else echo 'wireguard_interface=inactive'; fi
  handshake_age=$(wg show xconone0 latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2 > 0 {age=now-$2} END {print age=="" ? "none" : age}')
  echo "wireguard_handshake_age_seconds=$handshake_age"
  exit 1
}
[[ "$(cat /etc/xconnect-lab/node-role)" == controlled-client ]] || client_failure role
tls_verify=$(timeout 10 openssl s_client -connect "$2:443" -servername xconnect-lab.invalid \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>/dev/null \
  | awk '/Verify return code:/ {print $4; exit}' || true)
[[ "$tls_verify" == 0 ]] || client_failure tls-trust-or-transport
connected=0
for attempt in {1..30}; do
  if ping -c 1 -W 2 10.77.0.1 >/dev/null 2>&1 && curl --fail --max-time 5 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"; then connected=1; break; fi
  sleep 2
done
[[ "$connected" == 1 ]] || client_failure private-ping-http
pgrep -x xray >/dev/null || client_failure xray-process
wg show xconone0 latest-handshakes | awk -v peer="$3" -v now="$(date +%s)" '$1 == peer && $2 > 0 && now-$2 >= 0 && now-$2 < 180 {ok=1} END {exit !ok}' || client_failure wireguard-handshake
xconnect sync --state-dir /var/lib/xconnect-one >/dev/null || client_failure config-sync
xconnect status --state-dir /var/lib/xconnect-one | jq -e --arg device "$4" --arg network "$5" \
  '.joined == true and .device_id == $device and .network_id == $network and .generations.state > 0 and .runtime.applied == true and .runtime.core_id == "xray" and .credential.present == true and .credential.expired == false' \
  >/dev/null || client_failure signed-config-ack-status
curl --fail --max-time 10 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1" || client_failure post-sync-private-http
CLIENT_VERIFY
then
  ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s <<'GATEWAY_FAILURE_DIAGNOSTICS'
set -euo pipefail
if systemctl is-active --quiet xconnect-gateway-xray.service; then echo 'gateway_xray_process=active'; else echo 'gateway_xray_process=inactive'; fi
if ss -ltn | grep -Eq ':443[[:space:]]'; then echo 'gateway_xray_listener=active'; else echo 'gateway_xray_listener=inactive'; fi
if ip link show xconzero0 >/dev/null 2>&1; then echo 'gateway_wireguard_interface=active'; else echo 'gateway_wireguard_interface=inactive'; fi
handshake_age=$(wg show xconzero0 latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2 > 0 {age=now-$2} END {print age=="" ? "none" : age}')
echo "gateway_wireguard_handshake_age_seconds=$handshake_age"
GATEWAY_FAILURE_DIAGNOSTICS
  exit 1
fi

ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$client_public_key" "$gateway_id" "$network_id" "$formal_zero" <<'RELAY_VERIFY'
set -euo pipefail
wg show xconzero0 latest-handshakes | awk -v peer="$1" -v now="$(date +%s)" '$1 == peer && $2 > 0 && now-$2 >= 0 && now-$2 < 180 {ok=1} END {exit !ok}'
jq -e --arg gateway "$2" --arg network "$3" --arg controller "$4" \
  '.gateway_id == $gateway and .network_id == $network and .controller == $controller and .applied_generation > 0 and (.applied_config_id | length) > 0' \
  /var/lib/xconnect-gateway/state.json >/dev/null
ip route get 10.77.0.2 | grep -Fq 'dev xconzero0'
RELAY_VERIFY

echo 'PASS: formal UAT Accounts enrollment, released Gateway and Linux One, signed sync/ACK, external Xray/WireGuard, private ping/HTTP and exact-peer handshake on both sides.'
echo 'Not covered by Linux PASS: authenticated Portal data, macOS/Windows private HTTP, or policy enforcement/revocation.'
if [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" != 0 || "${NODE_OBSERVATION_WINDOW_MINUTES:-0}" != 0 ]]; then
  write_desktop_handoff
fi
}

write_desktop_handoff() {
  local public_dir="$LAB_DIR/desktop-public"
  local handoff="$public_dir/desktop-handoff.json"
  local gateway_instance gateway_private client_instance client_private expires
  gateway_instance=$(jq -er '.resource_ids.value.gateway' "$LAB_DIR/outputs.json")
  client_instance=$(jq -er '.resource_ids.value.client' "$LAB_DIR/outputs.json")
  gateway_private=$(jq -er '.gateway_private_ip.value' "$LAB_DIR/outputs.json")
  client_private=$(jq -er '.client_private_ip.value' "$LAB_DIR/outputs.json")
  expires=$(jq -er '.expires_at' "$LAB_DIR/variables.json")
  mkdir -p "$public_dir"
  install -m 644 "$LAB_DIR/tls/ca.crt" "$public_dir/ca.crt"
  jq -n \
    --arg run "$run_id" --arg expires "$expires" --arg network "$network_id" --arg gateway_id "$gateway_id" \
    --arg gateway_key "$gateway_public_key" --arg gateway_host "$gateway_transport" \
    --arg accounts "$formal_zero" --arg portal "$formal_portal" \
    --arg gateway_instance "$gateway_instance" --arg gateway_public "$gateway" --arg gateway_private "$gateway_private" \
    --arg client_instance "$client_instance" --arg client_public "$client" --arg client_private "$client_private" \
    '{run:$run,expires_at:$expires,network_id:$network,gateway_id:$gateway_id,gateway_public_key:$gateway_key,
      gateway_endpoint:{host:$gateway_host,port:443,server_name:"xconnect-lab.invalid"},
      accounts_url:$accounts,portal_url:$portal,
      instances:{gateway:{instance_id:$gateway_instance,public_ip:$gateway_public,private_ip:$gateway_private},
                 linux_one:{instance_id:$client_instance,public_ip:$client_public,private_ip:$client_private}},
      expected_device_ids:{darwin:("one-darwin-" + $run),windows:("one-windows-" + $run)},
      verification:{target:"http://10.77.0.1:8080/",expected_marker:$run}}' > "$handoff"
  chmod 644 "$handoff"
  python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-handoff "$handoff"
  unexpected=$(find "$public_dir" -mindepth 1 -maxdepth 1 ! -name ca.crt ! -name desktop-handoff.json -print -quit)
  [[ -z "$unexpected" ]] || { echo 'Public desktop handoff directory contains an unexpected entry'; exit 1; }
  [[ "$(find "$public_dir" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 2 ]] || { echo 'Public desktop handoff directory must contain exactly ca.crt and desktop-handoff.json'; exit 1; }
  echo "PUBLIC_DESKTOP_HANDOFF_READY run=$run_id expires_at=$expires"
}

stage="${1:-all}"
case "$stage" in
  setup) prepare_runtime ;;
  bootstrap) test -f "$LAB_DIR/setup.done"; bootstrap_accounts ;;
  gateway) test -f "$LAB_DIR/bootstrap.done"; enroll_gateway ;;
  one) test -f "$LAB_DIR/gateway.done"; enroll_one ;;
  verify) test -f "$LAB_DIR/one.done"; verify_overlay ;;
  all) prepare_runtime; bootstrap_accounts; enroll_gateway; enroll_one; verify_overlay ;;
  *) echo 'Unknown deployment stage' >&2; exit 1 ;;
esac
touch "$LAB_DIR/$stage.done"
