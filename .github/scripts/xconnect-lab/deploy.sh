#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${GITHUB_WORKSPACE:?}"
LAB_DIR="${LAB_DIR:?}"
DECL="$ROOT/gitops/topology/uat/xconnect-lab.json"
gateway=$(jq -er .gateway_ip.value "$LAB_DIR/outputs.json")
gateway_transport=$(jq -er .gateway_transport_ip.value "$LAB_DIR/outputs.json")
gateway_user=$(jq -er .gateway_ssh_user.value "$LAB_DIR/outputs.json")
client=$(jq -er .client_ip.value "$LAB_DIR/outputs.json")
client_user=$(jq -er .client_ssh_user.value "$LAB_DIR/outputs.json")
formal_zero=$(jq -er .zero_accounts_api_url.value "$LAB_DIR/outputs.json")
formal_portal=$(jq -er .zero_portal_url.value "$LAB_DIR/outputs.json")
network_id=$(jq -er .spec.overlay.network_id "$DECL")
run_id=$(<"$LAB_DIR/run-id")
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

wait_for_ssh "$gateway_user" "$gateway"
wait_for_ssh "$client_user" "$client"

mkdir -p "$LAB_DIR/tls"
openssl req -x509 -newkey rsa:3072 -nodes -days 1 -subj '/CN=XConnect disposable lab CA' -keyout "$LAB_DIR/tls/ca.key" -out "$LAB_DIR/tls/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:3072 -nodes -subj '/CN=xconnect-lab.invalid' -keyout "$LAB_DIR/tls/server.key" -out "$LAB_DIR/tls/server.csr" >/dev/null 2>&1
{
  printf 'subjectAltName=DNS:xconnect-lab.invalid,IP:%s' "$gateway"
  private_ip=$(jq -r .gateway_private_ip.value "$LAB_DIR/outputs.json")
  [[ -n "$private_ip" ]] && printf ',IP:%s' "$private_ip"
  printf '\nextendedKeyUsage=serverAuth\n'
} > "$LAB_DIR/tls/extensions"
openssl x509 -req -in "$LAB_DIR/tls/server.csr" -CA "$LAB_DIR/tls/ca.crt" -CAkey "$LAB_DIR/tls/ca.key" -CAcreateserial -days 1 -extfile "$LAB_DIR/tls/extensions" -out "$LAB_DIR/tls/server.crt" >/dev/null 2>&1
printf '%s' "$LAB_ADMIN_TOKEN" > "$LAB_DIR/admin-token"
printf '%s' "$LAB_SIGNING_KEY" > "$LAB_DIR/signing-key"
printf '%s' "$LAB_VLESS_ID" > "$LAB_DIR/vless-id"

# The local server is an experimental API-compatibility harness for cloud
# debugging. The formal accounts API and portal remain the only Zero source.
jq -n --arg formal "$formal_zero" --arg portal "$formal_portal" --arg role relay \
  --arg lab "https://$gateway:8443" \
  '{role:$role,config_source:{accounts_api_url:$formal,portal_url:$portal,authoritative:true},lab_controller:{url:$lab,purpose:"cloud-debug-only",authoritative:false}}' \
  > "$LAB_DIR/runtime-contract.json"
jq -n --arg formal "$formal_zero" --arg portal "$formal_portal" \
  '{role:"controlled-client",config_source:{accounts_api_url:$formal,portal_url:$portal,authoritative:true}}' \
  > "$LAB_DIR/client-runtime-contract.json"

ssh "${SSH[@]}" "$gateway_user@$gateway" 'sudo install -d -m 700 /opt/xconnect-lab'
echo 'Stage: Gateway artifact transfer'
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect-zero-lab" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/server.key" "$LAB_DIR/tls/server.crt" "$LAB_DIR/tls/ca.crt" "$LAB_DIR/admin-token" "$LAB_DIR/signing-key" "$LAB_DIR/vless-id" "$LAB_DIR/runtime-contract.json" "$ROOT/.github/scripts/xconnect-lab/gateway.sh" "$gateway_user@$gateway:/tmp/" >/dev/null || { echo 'Gateway artifact transfer failed'; exit 1; }
echo 'Stage: Gateway bootstrap'
ssh "${SSH[@]}" "$gateway_user@$gateway" "sudo install -m 755 /tmp/xconnect-zero-lab /tmp/xray /tmp/gateway.sh /opt/xconnect-lab; sudo install -m 600 /tmp/server.key /tmp/admin-token /tmp/signing-key /tmp/vless-id /opt/xconnect-lab; sudo install -m 644 /tmp/server.crt /tmp/ca.crt /tmp/runtime-contract.json /opt/xconnect-lab; sudo bash /opt/xconnect-lab/gateway.sh '$gateway_transport' '$run_id' '$formal_zero' '$formal_portal' '$network_id'" || { echo 'Gateway bootstrap failed'; exit 1; }

echo 'Stage: controlled-client artifact transfer'
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/ca.crt" "$LAB_DIR/client-runtime-contract.json" "$client_user@$client:/tmp/" >/dev/null || { echo 'Controlled-client artifact transfer failed'; exit 1; }
echo 'Stage: controlled-client bootstrap'
ssh "${SSH[@]}" "$client_user@$client" 'sudo install -m 755 /tmp/xconnect /tmp/xray /usr/local/bin/; sudo install -m 644 /tmp/ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt; sudo install -m 644 /tmp/client-runtime-contract.json /etc/xconnect-lab-runtime.json; sudo update-ca-certificates >/dev/null 2>&1; sudo install -d -m 700 /var/lib/xconnect-one /etc/xconnect-lab; sudo sh -c '\''printf "%s\n" controlled-client > /etc/xconnect-lab/node-role'\''; test "$(sudo cat /etc/xconnect-lab/node-role)" = controlled-client' || { echo 'Controlled-client bootstrap failed'; exit 1; }

# The join URI exercises the lab controller only as a disposable cloud-debug
# endpoint; production enrollment uses the formal Zero accounts API.
echo 'Stage: join URI transfer'
ssh "${SSH[@]}" "$gateway_user@$gateway" 'sudo cat /opt/xconnect-lab/join-uri' | ssh "${SSH[@]}" "$client_user@$client" 'sudo tee /var/lib/xconnect-one/join-uri >/dev/null' || { echo 'Join URI transfer failed'; exit 1; }
echo 'Stage: controlled-client join'
ssh "${SSH[@]}" "$client_user@$client" 'sudo chmod 600 /var/lib/xconnect-one/join-uri; sudo sh -c '\''xconnect join --state-dir /var/lib/xconnect-one --device-id dev_lab --name lab-client "$(cat /var/lib/xconnect-one/join-uri)"'\''' > "$LAB_DIR/join.log" 2>&1 || { echo 'Real invite enrollment/runtime startup failed (protected log)'; exit 1; }

# Verify the relay node independently, including its Linux role marker, external
# WireGuard/Xray services, TLS/API health and a recent peer handshake. Use the
# private transport address for this on-node check; the public address is only
# the runner's SSH target.
echo 'Stage: Gateway verification'
ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$gateway_transport" "$run_id" "$network_id" <<'GATEWAY_VERIFY' || { echo 'Gateway verification SSH command failed'; exit 1; }
set -euo pipefail
gateway_failure() {
  echo "Gateway verification failed: $1"
  systemctl is-active wg-quick@wg0 xconnect-lab-xray xconnect-lab-http xconnect-lab-zero || true
  ss -ltnup || true
  wg show wg0 || true
  exit 1
}
[[ "$(cat /etc/xconnect-lab/node-role)" == relay ]] || gateway_failure role
[[ "$(cat /etc/xconnect-lab/lab-run)" == "$2" ]] || gateway_failure run-marker
systemctl is-active --quiet wg-quick@wg0 || gateway_failure wireguard-service
systemctl is-active --quiet xconnect-lab-xray || gateway_failure xray-service
systemctl is-active --quiet xconnect-lab-http || gateway_failure private-http-service
systemctl is-active --quiet xconnect-lab-zero || gateway_failure zero-service
wg show wg0 >/dev/null || gateway_failure wireguard-interface
ss -ltn | grep -Eq ':443[[:space:]]' || gateway_failure xray-listener
ss -ltn | grep -Eq ':8443[[:space:]]' || gateway_failure zero-listener
status=$(curl --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 10 --output /dev/null --write-out '%{http_code}' --cacert /opt/xconnect-lab/ca.crt --resolve "$1:8443:127.0.0.1" "https://$1:8443/healthz") || gateway_failure zero-health-transport
[[ "$status" == 200 ]] || gateway_failure "zero-health-http-$status"
status=$(curl --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 10 --output /dev/null --write-out '%{http_code}' --cacert /opt/xconnect-lab/ca.crt --resolve "$1:8443:127.0.0.1" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"network_id\":\"$3\",\"device_id\":\"dev_verify\",\"platform\":\"linux\",\"expires_in_seconds\":60}" \
  "https://$1:8443/api/overlay/v1/join-tokens") || gateway_failure zero-api-transport
[[ "$status" == 401 || "$status" == 403 ]] || gateway_failure "zero-api-http-$status"
GATEWAY_VERIFY

# A local readiness ACK is insufficient. Assert the true client->relay path,
# client-side and relay-side WireGuard handshakes, external Xray and sync.
echo 'Stage: controlled-client verification'
ssh "${SSH[@]}" "$client_user@$client" sudo bash -s -- "$run_id" <<'CLIENT_VERIFY' || { echo 'Controlled-client verification SSH command failed'; exit 1; }
set -euo pipefail
client_failure() {
  echo "Client verification failed: $1"
  sudo ip -brief address show wg-xco || true
  sudo wg show all || true
  sudo ps -eo pid=,comm= | grep '[x]ray' || true
  exit 1
}
[[ "$(sudo cat /etc/xconnect-lab/node-role)" == controlled-client ]] || client_failure role
connected=0
for attempt in {1..30}; do
  if ping -c 1 -W 2 10.77.0.1 >/dev/null 2>&1 && curl --fail --max-time 5 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"; then connected=1; break; fi
  sleep 2
done
[[ "$connected" == 1 ]] || client_failure private-ping-http
ping -c 3 -W 3 10.77.0.1 >/dev/null || client_failure private-ping
curl --fail --max-time 10 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1" || client_failure private-http
pgrep -x xray >/dev/null || client_failure xray-process
wg show all latest-handshakes | awk -v now="$(date +%s)" '$3 > 0 && now-$3 < 180 {ok=1} END {exit !ok}' || client_failure wireguard-handshake
if ! xconnect sync --state-dir /var/lib/xconnect-one >/dev/null 2>&1; then
  client_failure sync
fi
curl --fail --max-time 10 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1" || client_failure post-sync-private-http
if ! xconnect down --state-dir /var/lib/xconnect-one >/dev/null 2>&1; then
  client_failure down
fi
if curl --fail --max-time 3 --noproxy '*' -s http://10.77.0.1:8080/ >/dev/null 2>&1; then
  echo 'Private service unexpectedly reachable after tunnel teardown'; exit 1
fi
CLIENT_VERIFY

echo 'Stage: relay verification'
ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$run_id" <<'RELAY_VERIFY' || { echo 'Relay verification SSH command failed'; exit 1; }
set -euo pipefail
relay_failure() {
  echo "Relay verification failed: $1"
  ip route show table main || true
  wg show wg0 || true
  exit 1
}
[[ "$(cat /etc/xconnect-lab/node-role)" == relay ]] || relay_failure role
wg show wg0 latest-handshakes | awk -v now="$(date +%s)" '$3 > 0 && now-$3 < 180 {ok=1} END {exit !ok}' || relay_failure wireguard-handshake
ip route get 10.77.0.2 | grep -Fq 'dev wg0' || relay_failure peer-route
RELAY_VERIFY

echo 'PASS: AWS/Vultr relay + controlled-client Linux baseline, signed lab enrollment, external Xray/WireGuard, relay health, private ping/HTTP, both-side handshake, sync, and tunnel-down isolation.'
