#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="${GITHUB_WORKSPACE:?}"
LAB_DIR="${LAB_DIR:?}"
gateway=$(jq -er .gateway_ip.value "$LAB_DIR/outputs.json")
client=$(jq -er .client_ip.value "$LAB_DIR/outputs.json")
SSH=(-i "$LAB_DIR/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
# First use is pinned in this fresh run's known_hosts; later changes fail closed.
for target in "root@$gateway" "ubuntu@$client"; do
  ready=false
  for attempt in {1..60}; do
    if ssh "${SSH[@]}" "$target" true 2>/dev/null; then ready=true; break; fi
    sleep 5
  done
  "$ready" || { echo 'SSH bootstrap unavailable'; exit 1; }
  ssh "${SSH[@]}" "$target" 'sudo cloud-init status --wait >/dev/null 2>&1; sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools curl ca-certificates python3 openssl >/dev/null 2>&1'
done
mkdir -p "$LAB_DIR/tls"
openssl req -x509 -newkey rsa:3072 -nodes -days 1 -subj '/CN=XConnect disposable lab CA' -keyout "$LAB_DIR/tls/ca.key" -out "$LAB_DIR/tls/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:3072 -nodes -subj '/CN=xconnect-lab.invalid' -keyout "$LAB_DIR/tls/server.key" -out "$LAB_DIR/tls/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:xconnect-lab.invalid,IP:%s\nextendedKeyUsage=serverAuth\n' "$gateway" > "$LAB_DIR/tls/extensions"
openssl x509 -req -in "$LAB_DIR/tls/server.csr" -CA "$LAB_DIR/tls/ca.crt" -CAkey "$LAB_DIR/tls/ca.key" -CAcreateserial -days 1 -extfile "$LAB_DIR/tls/extensions" -out "$LAB_DIR/tls/server.crt" >/dev/null 2>&1
printf '%s' "$LAB_ADMIN_TOKEN" > "$LAB_DIR/admin-token"
printf '%s' "$LAB_SIGNING_KEY" > "$LAB_DIR/signing-key"
printf '%s' "$LAB_VLESS_ID" > "$LAB_DIR/vless-id"
ssh "${SSH[@]}" "root@$gateway" 'install -d -m 700 /opt/xconnect-lab'
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect-zero-lab" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/server.key" "$LAB_DIR/tls/server.crt" "$LAB_DIR/tls/ca.crt" "$LAB_DIR/admin-token" "$LAB_DIR/signing-key" "$LAB_DIR/vless-id" "$ROOT/.github/scripts/xconnect-lab/gateway.sh" "root@$gateway:/opt/xconnect-lab/" >/dev/null
ssh "${SSH[@]}" "root@$gateway" bash /opt/xconnect-lab/gateway.sh "$gateway" "$(<"$LAB_DIR/run-id")" > "$LAB_DIR/gateway.log" 2>&1 || { echo 'Gateway bootstrap failed (protected log on runner)'; exit 1; }
scp "${SSH[@]}" "$LAB_DIR/bin/xconnect" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/ca.crt" "ubuntu@$client:/tmp/" >/dev/null
ssh "${SSH[@]}" "ubuntu@$client" 'sudo install -m 755 /tmp/xconnect /tmp/xray /usr/local/bin/; sudo install -m 644 /tmp/ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt; sudo update-ca-certificates >/dev/null 2>&1; sudo install -d -m 700 /var/lib/xconnect-one'
# Invite is issued over verified TLS on the gateway loopback and transferred over SSH.
ssh "${SSH[@]}" "root@$gateway" 'cat /opt/xconnect-lab/join-uri' | ssh "${SSH[@]}" "ubuntu@$client" 'sudo tee /var/lib/xconnect-one/join-uri >/dev/null'
ssh "${SSH[@]}" "ubuntu@$client" 'sudo chmod 600 /var/lib/xconnect-one/join-uri; sudo sh -c '\''xconnect join --state-dir /var/lib/xconnect-one --device-id dev_lab --name lab-client "$(cat /var/lib/xconnect-one/join-uri)"'\''' > "$LAB_DIR/join.log" 2>&1 || { echo 'Real invite enrollment/runtime startup failed (protected log)'; exit 1; }
# A local readiness ACK is insufficient. Assert a recent cryptographic handshake and private HTTP.
ssh "${SSH[@]}" "ubuntu@$client" sudo bash -s -- "$(<"$LAB_DIR/run-id")" <<'VERIFY'
set -euo pipefail
for attempt in {1..30}; do
  if ping -c 1 -W 2 10.77.0.1 >/dev/null 2>&1 && curl --fail --max-time 5 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"; then break; fi
  sleep 2
done
ping -c 3 -W 3 10.77.0.1 >/dev/null
curl --fail --max-time 10 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"
wg show all latest-handshakes | awk -v now="$(date +%s)" '$3 > 0 && now-$3 < 180 {ok=1} END {exit !ok}'
xconnect sync --state-dir /var/lib/xconnect-one >/dev/null 2>&1
curl --fail --max-time 10 --noproxy '*' -s http://10.77.0.1:8080/ | grep -Fxq "$1"
xconnect down --state-dir /var/lib/xconnect-one >/dev/null 2>&1
if curl --fail --max-time 3 --noproxy '*' -s http://10.77.0.1:8080/ >/dev/null 2>&1; then
  echo 'Private service unexpectedly reachable after tunnel teardown'; exit 1
fi
VERIFY
echo 'PASS: real signed enrollment, external Xray/WireGuard handshake, private ping/HTTP, sync, and tunnel-down isolation.'
