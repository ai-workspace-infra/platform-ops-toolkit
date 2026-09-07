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
  jq -er .join_uri "$response" > "$destination"
  chmod 600 "$destination"
}

echo 'Stage: formal Gateway enrollment and apply'
create_invite gateway "$gateway_id" "$LAB_DIR/invites/gateway"
scp "${SSH[@]}" "$LAB_DIR/invites/gateway" "$gateway_user@$gateway:/tmp/gateway-invite" >/dev/null
ssh "${SSH[@]}" "$gateway_user@$gateway" "sudo install -m 600 /tmp/gateway-invite /opt/xconnect-lab/gateway-invite; sudo sh -c 'xconnect-gateway join --state-dir /var/lib/xconnect-gateway --gateway-id \"$gateway_id\" \"\$(cat /opt/xconnect-lab/gateway-invite)\"'; sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway; sudo systemctl enable --now xconnect-gateway-sync.timer xconnect-lab-http.service"

echo 'Stage: controlled-client formal enrollment and apply'
create_invite one "$client_id" "$LAB_DIR/invites/one"
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/ca.crt" "$LAB_DIR/invites/one" "$client_user@$client:/tmp/" >/dev/null
ssh "${SSH[@]}" "$client_user@$client" "sudo install -m 755 /tmp/xconnect /tmp/xray /usr/local/bin/; sudo install -m 644 /tmp/ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt; sudo update-ca-certificates >/dev/null 2>&1; sudo install -d -m 700 /var/lib/xconnect-one /etc/xconnect-lab; sudo install -m 600 /tmp/one /var/lib/xconnect-one/join-uri; printf '%s\n' controlled-client | sudo tee /etc/xconnect-lab/node-role >/dev/null; sudo sh -c 'xconnect join --state-dir /var/lib/xconnect-one --device-id \"$client_id\" --name uat-linux-one \"\$(cat /var/lib/xconnect-one/join-uri)\"'"

# One enrollment advances the centralized generation. Reconcile the Gateway so
# its WireGuard peer set contains the newly registered controlled client.
ssh "${SSH[@]}" "$gateway_user@$gateway" 'sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway'

echo 'Stage: three-party runtime verification'
ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$run_id" <<'GATEWAY_VERIFY'
set -euo pipefail
[[ "$(cat /etc/xconnect-lab/node-role)" == relay ]]
[[ "$(cat /etc/xconnect-lab/lab-run)" == "$1" ]]
systemctl is-active --quiet xconnect-gateway-xray.service
systemctl is-active --quiet xconnect-lab-http.service
wg show xconzero0 >/dev/null
ss -ltn | grep -Eq ':443[[:space:]]'
xconnect-gateway status --state-dir /var/lib/xconnect-gateway
GATEWAY_VERIFY

ssh "${SSH[@]}" "$client_user@$client" sudo bash -s -- "$run_id" <<'CLIENT_VERIFY'
set -euo pipefail
[[ "$(cat /etc/xconnect-lab/node-role)" == controlled-client ]]
connected=0
for attempt in {1..30}; do
  if ping -c 1 -W 2 10.77.0.1 >/dev/null 2>&1 && curl --fail --max-time 5 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"; then connected=1; break; fi
  sleep 2
done
[[ "$connected" == 1 ]]
pgrep -x xray >/dev/null
wg show xconone0 latest-handshakes | awk -v now="$(date +%s)" '$2 > 0 && now-$2 < 180 {ok=1} END {exit !ok}'
xconnect sync --state-dir /var/lib/xconnect-one >/dev/null
curl --fail --max-time 10 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"
CLIENT_VERIFY

ssh "${SSH[@]}" "$gateway_user@$gateway" sudo bash -s <<'RELAY_VERIFY'
set -euo pipefail
wg show xconzero0 latest-handshakes | awk -v now="$(date +%s)" '$2 > 0 && now-$2 < 180 {ok=1} END {exit !ok}'
ip route get 10.77.0.2 | grep -Fq 'dev xconzero0'
RELAY_VERIFY

echo 'PASS: formal UAT Accounts/Portal, released Gateway and Linux One, centralized signed sync, external Xray/WireGuard, private ping/HTTP and both-side handshake.'
