#!/usr/bin/env bash
set -euo pipefail
umask 077
cd /opt/xconnect-lab
gateway="${1:?gateway IPv4}"
run="${2:?run identity}"
chmod 600 admin-token signing-key vless-id server.key
install -m 755 xray xconnect-zero-lab /usr/local/bin/
install -m 644 ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt
update-ca-certificates >/dev/null 2>&1
install -d -m 700 /etc/wireguard /var/lib/xconnect-zero-lab /usr/local/libexec
wg genkey > /etc/wireguard/lab.key
wg pubkey < /etc/wireguard/lab.key > gateway.pub
ip link add wg0 type wireguard
ip address add 10.77.0.1/24 dev wg0
wg set wg0 private-key /etc/wireguard/lab.key listen-port 51820
ip link set wg0 up
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
(p/'http').mkdir()
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
/usr/local/bin/xray run -test -config /opt/xconnect-lab/xray.json >/dev/null 2>&1
systemd-run --unit=xconnect-lab-xray --property=Restart=on-failure /usr/local/bin/xray run -config /opt/xconnect-lab/xray.json >/dev/null
systemd-run --unit=xconnect-lab-http /usr/bin/python3 -m http.server 8080 --bind 10.77.0.1 --directory /opt/xconnect-lab/http >/dev/null
systemd-run --unit=xconnect-lab-zero --property=Restart=on-failure /usr/local/bin/xconnect-zero-lab \
  --listen :8443 --public-url "https://$gateway:8443" --state /var/lib/xconnect-zero-lab/state.json \
  --tls-cert /opt/xconnect-lab/server.crt --tls-key /opt/xconnect-lab/server.key \
  --admin-token-file /opt/xconnect-lab/admin-token --signing-key-file /opt/xconnect-lab/signing-key \
  --network-id net_lab --network-cidr 10.77.0.0/24 --device-address 10.77.0.2/32 \
  --gateway-public-key "$(<gateway.pub)" --gateway-host "$gateway" --gateway-port 443 \
  --gateway-server-name xconnect-lab.invalid --vless-id-file /opt/xconnect-lab/vless-id \
  --peer-command /usr/local/libexec/xconnect-lab-peer >/dev/null
python3 - "$gateway" <<'PY'
import json, pathlib, ssl, sys, time, urllib.request
p = pathlib.Path('/opt/xconnect-lab')
# Connect locally while validating the certificate against the real public IP.
import http.client
class LocalHTTPS(http.client.HTTPSConnection):
    def connect(self):
        import socket
        self.sock = self._context.wrap_socket(socket.create_connection(('127.0.0.1', 8443), 5), server_hostname=self.host)
for attempt in range(30):
    try:
        conn = LocalHTTPS(sys.argv[1], context=ssl.create_default_context(cafile=str(p/'ca.crt')))
        conn.request('POST', '/api/overlay/v1/join-tokens', body=json.dumps({
            'network_id': 'net_lab', 'device_id': 'dev_lab', 'platform': 'linux', 'expires_in_seconds': 900}),
            headers={'Authorization': 'Bearer '+(p/'admin-token').read_text().strip(), 'Content-Type': 'application/json'})
        response = conn.getresponse()
        if response.status not in (200, 201):
            raise RuntimeError('Invite issuance rejected')
        data = json.load(response)
        (p/'join-uri').write_text(data['join_token']['join_uri'])
        break
    except (OSError, RuntimeError):
        if attempt == 29:
            raise SystemExit('Controller did not issue a real invite')
        time.sleep(2)
PY
