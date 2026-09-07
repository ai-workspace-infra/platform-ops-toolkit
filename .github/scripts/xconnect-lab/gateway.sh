#!/usr/bin/env bash
set -euo pipefail
umask 077
cd /opt/xconnect-lab

gateway="${1:?gateway transport IPv4}"
run="${2:?run identity}"
formal_zero="${3:?formal Zero accounts API URL}"
formal_portal="${4:?formal Zero portal URL}"
network_id="${5:?overlay network ID}"
chmod 600 admin-token signing-key vless-id server.key
install -m 755 xray xconnect-zero-lab /usr/local/bin/
install -m 644 ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt
update-ca-certificates >/dev/null 2>&1
install -d -m 700 /etc/wireguard /var/lib/xconnect-zero-lab /usr/local/libexec

# Gateway is a relay/service Linux node: WireGuard and Xray are independent
# external processes, while the temporary API harness is debug-only.
printf '%s\n' relay > /etc/xconnect-lab/node-role
printf '%s\n' "$run" > /etc/xconnect-lab/lab-run
jq -n --arg formal "$formal_zero" --arg portal "$formal_portal" --arg lab "https://$gateway:8443" \
  '{role:"relay",config_source:{accounts_api_url:$formal,portal_url:$portal,authoritative:true},lab_controller:{url:$lab,purpose:"cloud-debug-only",authoritative:false}}' \
  > /opt/xconnect-lab/runtime-contract.json

if [[ ! -s /etc/wireguard/lab.key ]]; then
  wg genkey > /etc/wireguard/lab.key
fi
wg pubkey < /etc/wireguard/lab.key > gateway.pub
cat > /etc/wireguard/wg0.conf <<WG
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = $(< /etc/wireguard/lab.key)
SaveConfig = false
WG
chmod 600 /etc/wireguard/wg0.conf
ip link delete wg0 2>/dev/null || true

python3 - "$run" <<'PY'
import json, pathlib, sys
p = pathlib.Path('/opt/xconnect-lab')
config = {'log': {'loglevel': 'warning'}, 'inbounds': [{
    'listen': '0.0.0.0', 'port': 443, 'protocol': 'vless',
    'settings': {'clients': [{'id': (p/'vless-id').read_text().strip()}], 'decryption': 'none'},
    'streamSettings': {'network': 'tcp', 'security': 'tls', 'tlsSettings': {
        'certificates': [{'certificateFile': str(p/'server.crt'), 'keyFile': str(p/'server.key')}]}}}],
    'outbounds': [{'tag': 'wg-only', 'protocol': 'freedom'}, {'tag': 'deny', 'protocol': 'blackhole'}],
    'routing': {'rules': [
        {'type': 'field', 'ip': ['127.0.0.1/32'], 'port': '51820', 'network': 'udp', 'outboundTag': 'wg-only'},
        {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'deny'}]}}
(p/'xray.json').write_text(json.dumps(config))
(p/'http').mkdir(exist_ok=True)
(p/'http'/'index.html').write_text(sys.argv[1]+'\n')
helper = pathlib.Path('/usr/local/libexec/xconnect-lab-peer')
helper.write_text('''#!/usr/bin/env python3
import base64, subprocess, sys
if len(sys.argv) != 3 or sys.argv[2] != "10.77.0.2/32":
    sys.exit(1)
try:
    if len(base64.b64decode(sys.argv[1], validate=True)) != 32:
        sys.exit(1)
except ValueError:
    sys.exit(1)
subprocess.run(["wg", "set", "wg0", "peer", sys.argv[1], "allowed-ips", sys.argv[2]], check=True)
''')
helper.chmod(0o700)
PY

cat > /etc/systemd/system/xconnect-lab-xray.service <<'UNIT'
[Unit]
Description=XConnect Gateway relay external Xray
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
Requires=wg-quick@wg0.service
[Service]
ExecStart=/usr/local/bin/xray run -config /opt/xconnect-lab/xray.json
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/xconnect-lab-http.service <<'UNIT'
[Unit]
Description=XConnect Gateway private relay probe
After=wg-quick@wg0.service
Requires=wg-quick@wg0.service
[Service]
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 10.77.0.1 --directory /opt/xconnect-lab/http
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/xconnect-lab-zero.service <<'UNIT'
[Unit]
Description=Experimental XConnect Zero API compatibility harness for lab debugging
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/xconnect-zero-lab --listen 0.0.0.0:8443 --public-url https://PLACEHOLDER:8443 --state /var/lib/xconnect-zero-lab/state.json --tls-cert /opt/xconnect-lab/server.crt --tls-key /opt/xconnect-lab/server.key --admin-token-file /opt/xconnect-lab/admin-token --signing-key-file /opt/xconnect-lab/signing-key --network-id NETWORK_ID --network-cidr 10.77.0.0/24 --device-address 10.77.0.2/32 --gateway-public-key PLACEHOLDER_KEY --gateway-host PLACEHOLDER --gateway-port 443 --gateway-server-name xconnect-lab.invalid --vless-id-file /opt/xconnect-lab/vless-id --peer-command /usr/local/libexec/xconnect-lab-peer
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
gateway_pub=$(<gateway.pub)
sed -i "s/PLACEHOLDER_KEY/$gateway_pub/; s/PLACEHOLDER/$gateway/g; s/NETWORK_ID/$network_id/g" /etc/systemd/system/xconnect-lab-zero.service
/usr/local/bin/xray run -test -config /opt/xconnect-lab/xray.json >/dev/null 2>&1
systemctl daemon-reload
systemctl enable --now wg-quick@wg0
systemctl enable --now xconnect-lab-xray xconnect-lab-http xconnect-lab-zero

for attempt in {1..30}; do
  systemctl is-active --quiet wg-quick@wg0 &&
    systemctl is-active --quiet xconnect-lab-xray &&
    systemctl is-active --quiet xconnect-lab-zero && break
  [[ "$attempt" == 30 ]] && { echo 'Gateway relay services did not become healthy'; exit 1; }
  sleep 2
done
health_status=000
for attempt in {1..30}; do
  if health_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert /opt/xconnect-lab/ca.crt --resolve "$gateway:8443:127.0.0.1" \
    --connect-timeout 2 --max-time 5 "https://$gateway:8443/healthz"); then
    if [[ "$health_status" == 200 ]]; then
      break
    fi
  else
    health_status=000
  fi
  if [[ "$attempt" == 30 ]]; then
    echo "Experimental Zero API TLS health check failed with HTTP status $health_status"
    systemctl is-active wg-quick@wg0 xconnect-lab-xray xconnect-lab-http xconnect-lab-zero || true
    echo 'Listening TCP sockets:'
    ss -ltnp || true
    echo 'Zero API service status:'
    systemctl --no-pager --full status xconnect-lab-zero.service | tail -n 30 || true
    echo 'Recent Zero API service log:'
    journalctl -u xconnect-lab-zero.service -n 30 --no-pager || true
    exit 1
  fi
  sleep 2
done

# Issue one disposable enrollment from the lab API harness. This is a joint
# debug fixture, never the formal accounts/portal configuration source.
request_body=$(mktemp)
response_body=$(mktemp)
trap 'rm -f "$request_body" "$response_body"' EXIT
printf '{"network_id":"%s","device_id":"dev_lab","platform":"linux","expires_in_seconds":900}\n' "$network_id" > "$request_body"
admin_token=$(<admin-token)
status=000
for attempt in {1..30}; do
  status=$(curl --silent --show-error --output "$response_body" --write-out '%{http_code}' \
    --cacert ca.crt --resolve "$gateway:8443:127.0.0.1" \
    -H "Authorization: Bearer $admin_token" -H 'Accept: application/json' \
    -H 'Content-Type: application/json' --data-binary "@$request_body" \
    "https://$gateway:8443/api/overlay/v1/join-tokens" || true)
  if [[ "$status" == 200 || "$status" == 201 ]]; then
    jq -er .join_token.join_uri "$response_body" > join-uri
    chmod 600 join-uri
    break
  fi
  [[ "$attempt" == 30 ]] && {
    error_body=$(tr '\n' ' ' < "$response_body" | cut -c 1-240)
    echo "Lab Zero API harness did not issue a real debug invite: HTTP $status: $error_body"
    exit 1
  }
  sleep 2
done
