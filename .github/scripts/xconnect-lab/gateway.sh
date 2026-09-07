#!/usr/bin/env bash
set -euo pipefail
umask 077

gateway_transport="${1:?gateway transport IPv4}"
run="${2:?run identity}"
formal_zero="${3:?formal Zero accounts API URL}"
formal_portal="${4:?formal Zero portal URL}"
network_id="${5:?overlay network ID}"
gateway_id="${6:?gateway ID}"

install -d -m 700 /opt/xconnect-lab /var/lib/xconnect-gateway /etc/xconnect-gateway
install -m 755 /tmp/xconnect-gateway /tmp/xray /usr/local/bin/
install -m 600 /tmp/server.key /etc/xconnect-gateway/tls.key
install -m 644 /tmp/server.crt /etc/xconnect-gateway/tls.crt
install -m 644 /tmp/ca.crt /usr/local/share/ca-certificates/xconnect-lab.crt
update-ca-certificates >/dev/null 2>&1

cat > /etc/sysctl.d/99-xconnect-lab-gateway.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
SYSCTL
sysctl -q -p /etc/sysctl.d/99-xconnect-lab-gateway.conf

install -d -m 755 /etc/xconnect-lab
printf '%s\n' relay > /etc/xconnect-lab/node-role
printf '%s\n' "$run" > /etc/xconnect-lab/lab-run
jq -n --arg formal "$formal_zero" --arg portal "$formal_portal" --arg network "$network_id" \
  '{role:"relay",network_id:$network,config_source:{accounts_api_url:$formal,portal_url:$portal,authoritative:true}}' \
  > /opt/xconnect-lab/runtime-contract.json

cat > /etc/systemd/system/xconnect-gateway-xray.service <<'UNIT'
[Unit]
Description=XConnect Gateway external Xray runtime
After=network-online.target
Wants=network-online.target
[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /var/lib/xconnect-gateway/runtime/xray.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/xconnect-gateway-sync.service <<'UNIT'
[Unit]
Description=Synchronize XConnect Gateway with XConnect Zero
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/xconnect-gateway up --state-dir /var/lib/xconnect-gateway
UNIT

cat > /etc/systemd/system/xconnect-gateway-sync.timer <<'UNIT'
[Unit]
Description=Periodic XConnect Gateway configuration reconciliation
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
UNIT

install -d -m 755 /opt/xconnect-lab/http
printf '%s\n' "$run" > /opt/xconnect-lab/http/index.html
cat > /etc/systemd/system/xconnect-lab-http.service <<'UNIT'
[Unit]
Description=XConnect Gateway private relay probe
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 10.77.0.1 --directory /opt/xconnect-lab/http
Restart=always
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
xconnect-gateway diagnose >/dev/null
xconnect-gateway init --state-dir /var/lib/xconnect-gateway --controller "$formal_zero" --gateway-id "$gateway_id" > /opt/xconnect-lab/gateway-init
sed -n 's/^wireguard_public_key=//p' /opt/xconnect-lab/gateway-init > /opt/xconnect-lab/gateway.pub
chmod 600 /opt/xconnect-lab/gateway-init /opt/xconnect-lab/gateway.pub
[[ "$(wc -c < /opt/xconnect-lab/gateway.pub)" -ge 44 ]] || {
  echo 'Gateway runtime did not generate a WireGuard public key'
  exit 1
}
printf '%s\n' "$gateway_transport" > /opt/xconnect-lab/gateway-transport
