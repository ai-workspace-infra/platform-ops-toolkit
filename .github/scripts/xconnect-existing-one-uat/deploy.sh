#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${GITHUB_WORKSPACE:?}"
: "${LAB_DIR:?}"
: "${CLI_RELEASE_TOKEN:?}"
: "${CLI_RELEASE_TAG:?}"
: "${GATEWAY_RELEASE_TAG:?}"
: "${XRAY_RELEASE_TAG:?}"
: "${ZERO_ACCOUNTS_API_URL:?}"
: "${ZERO_SERVICE_TOKEN:?}"
: "${ZERO_OWNER_EMAIL:?}"
: "${LAB_VLESS_ID:?}"
: "${ZERO_NETWORK_ID:?}"
: "${ONE_DEVICE_ID:?}"
: "${ONE_SERVER_NAME:?}"
: "${ONE_HOST:?}"
: "${ONE_USER:?}"
: "${ONE_SSH_PRIVATE_KEY_B64:?}"
: "${ONE_BECOME_PASSWORD:?}"
: "${GATEWAY_HOST:?}"
: "${GATEWAY_USER:?}"
: "${GATEWAY_SSH_PASSWORD:?}"
: "${GATEWAY_TLS_CERT_B64:?}"
: "${GATEWAY_TLS_KEY_B64:?}"
: "${GATEWAY_SERVER_NAME:?}"
: "${OBSERVABILITY_USER:?}"
: "${OBSERVABILITY_PASSWORD:?}"

if [[ "$ONE_HOST" != "$ONE_SERVER_NAME" ]]; then
  mapfile -t one_server_ipv4 < <(getent ahostsv4 "$ONE_SERVER_NAME" | awk '{print $1}' | sort -u)
  printf '%s\n' "${one_server_ipv4[@]}" | grep -Fxq "$ONE_HOST" || {
    echo 'UAT existing-One SSH target does not match the authorized server name' >&2
    exit 1
  }
fi
[[ "$ONE_USER" == "root" || "$ONE_USER" == "ubuntu" ]] || {
  echo 'UAT existing-One target must use an authorized administrative SSH account' >&2
  exit 1
}

mkdir -p "$LAB_DIR/releases"
known_hosts="$LAB_DIR/known_hosts"
one_key="$LAB_DIR/one.ssh"
one_become_password="$LAB_DIR/one.become-password"
gateway_key="$LAB_DIR/gateway.ssh"
gateway_tls_cert="$LAB_DIR/gateway.tls.crt"
gateway_tls_key="$LAB_DIR/gateway.tls.key"
zero_header="$LAB_DIR/zero.header"
gateway_invite="$LAB_DIR/gateway.invite"
invite="$LAB_DIR/one.invite"
gateway_binary="$LAB_DIR/releases/xconnect-gateway"
xray_binary="$LAB_DIR/releases/xray"
probe_dir=''

cleanup() {
  if [[ -n "$probe_dir" ]]; then
    "${gateway_ssh[@]:-false}" "$GATEWAY_USER@$GATEWAY_HOST" \
      "sudo test -s '$probe_dir/pid' && sudo kill \"\$(sudo cat '$probe_dir/pid')\" 2>/dev/null || true; sudo rm -rf '$probe_dir'" \
      >/dev/null 2>&1 || true
  fi
  rm -f "$one_key" "$one_become_password" "$gateway_key" "$gateway_tls_cert" "$gateway_tls_key" \
    "$zero_header" "$gateway_invite" "$invite" "$LAB_DIR/xconnect" \
    "$gateway_binary" "$xray_binary" "$LAB_DIR/releases/SHA256SUMS" \
    "$LAB_DIR/releases/SHA256SUMS.selected" "$LAB_DIR/releases/gateway/SHA256SUMS" \
    "$LAB_DIR/releases/gateway/SHA256SUMS.selected" "$LAB_DIR/releases/xray.zip" \
    "$LAB_DIR/releases/xray.zip.dgst" \
    "$LAB_DIR/releases/xconnect-linux-amd64" "$LAB_DIR/releases/xconnect-linux-arm64"
}
trap cleanup EXIT

printf '%s' "$ONE_SSH_PRIVATE_KEY_B64" | base64 --decode >"$one_key"
printf '%s\n' "$ONE_BECOME_PASSWORD" >"$one_become_password"
printf 'X-Service-Token: %s\nContent-Type: application/json\n' "$ZERO_SERVICE_TOKEN" >"$zero_header"
printf '%s' "$GATEWAY_TLS_CERT_B64" | base64 --decode >"$gateway_tls_cert"
printf '%s' "$GATEWAY_TLS_KEY_B64" | base64 --decode >"$gateway_tls_key"
chmod 600 "$one_key" "$one_become_password" "$gateway_tls_cert" "$gateway_tls_key" "$zero_header"

openssl x509 -in "$gateway_tls_cert" -noout >/dev/null
openssl pkey -in "$gateway_tls_key" -noout >/dev/null
openssl x509 -in "$gateway_tls_cert" -checkhost "$GATEWAY_SERVER_NAME" -noout >/dev/null
openssl x509 -in "$gateway_tls_cert" -checkend 86400 -noout >/dev/null
cert_pub_hash="$(openssl x509 -in "$gateway_tls_cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
key_pub_hash="$(openssl pkey -in "$gateway_tls_key" -pubout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
[[ "$cert_pub_hash" == "$key_pub_hash" ]] || { echo 'Gateway TLS certificate and key do not match' >&2; exit 1; }
if [[ -n "${GATEWAY_TLS_NOT_AFTER_EPOCH:-}" ]]; then
  [[ "$GATEWAY_TLS_NOT_AFTER_EPOCH" =~ ^[0-9]+$ ]] || { echo 'Gateway TLS expiry metadata is invalid' >&2; exit 1; }
  (( GATEWAY_TLS_NOT_AFTER_EPOCH > $(date +%s) + 86400 )) || { echo 'Gateway TLS certificate expires within 24 hours' >&2; exit 1; }
fi

ssh-keyscan -H "$ONE_HOST" "$GATEWAY_HOST" >"$known_hosts" 2>/dev/null
test -s "$known_hosts" || { echo 'SSH host key discovery failed' >&2; exit 1; }

SSH_COMMON=(-o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
one_ssh=(ssh -o BatchMode=yes -i "$one_key" "${SSH_COMMON[@]}")
export SSHPASS="$GATEWAY_SSH_PASSWORD"
gateway_ssh=(sshpass -e ssh -o BatchMode=no -o PreferredAuthentications=password "${SSH_COMMON[@]}")
gateway_scp=(sshpass -e scp -o BatchMode=no -o PreferredAuthentications=password "${SSH_COMMON[@]}")

one_sudo() {
  local command="$1"
  printf '%s\n' "$ONE_BECOME_PASSWORD" | \
    "${one_ssh[@]}" "$ONE_USER@$ONE_HOST" "sudo -S -p '' $command"
}

echo 'Stage: verify the fixed UAT One declaration'
declaration="$GITHUB_WORKSPACE/gitops/vpn-overlay/uat/xconnect-one-nodes.yaml"
overlay_cidr="$(awk '$1 == "cidr:" {print $2; exit}' "$declaration")"
gateway_address="${GATEWAY_WIREGUARD_ADDRESS:-$(awk '$1 == "gateway_wireguard_address:" {print $2; exit}' "$declaration")}"
gateway_wireguard_ip="${gateway_address%/*}"
[[ -n "$overlay_cidr" && -n "$gateway_address" ]] || { echo 'UAT declaration must provide overlay CIDR and Gateway WireGuard address' >&2; exit 1; }
python3 - "$gateway_address" "$overlay_cidr" <<'PY'
import ipaddress
import sys
gateway = ipaddress.ip_interface(sys.argv[1])
network = ipaddress.ip_network(sys.argv[2], strict=False)
if gateway.version != 4 or gateway.network.prefixlen != 32 or str(gateway) != sys.argv[1] or gateway.ip not in network:
    raise SystemExit('Gateway WireGuard address must be a canonical IPv4 /32 inside the overlay CIDR')
PY
grep -Fq 'gateway_ref: ph-xconnect.svc.plus' "$declaration"
grep -Fq 'fqdn: observability.svc.plus' "$declaration"
grep -Fq 'lifecycle: persistent' "$declaration"

echo 'Stage: download and verify the reviewed Linux CLI release'
arch="$(${one_ssh[@]} "$ONE_USER@$ONE_HOST" uname -m)"
case "$arch" in
  x86_64|amd64) asset='xconnect-linux-amd64' ;;
  aarch64|arm64) asset='xconnect-linux-arm64' ;;
  *) echo "Unsupported existing One architecture: $arch" >&2; exit 1 ;;
esac
GH_TOKEN="$CLI_RELEASE_TOKEN" gh release download "$CLI_RELEASE_TAG" \
  --repo ai-workspace-xstream/XConnect-One \
  --pattern "$asset" --pattern SHA256SUMS \
  --dir "$LAB_DIR/releases" --clobber >/dev/null
awk -v asset="$asset" '$2 == asset || $2 == "dist/" asset {sub("dist/", "", $2); print}' \
  "$LAB_DIR/releases/SHA256SUMS" >"$LAB_DIR/releases/SHA256SUMS.selected"
[[ -s "$LAB_DIR/releases/SHA256SUMS.selected" ]]
(cd "$LAB_DIR/releases" && sha256sum -c SHA256SUMS.selected >/dev/null)
install -m 755 "$LAB_DIR/releases/$asset" "$LAB_DIR/xconnect"

echo 'Stage: install Gateway runtime and shared TLS certificate'
gateway_arch="$(${gateway_ssh[@]} "$GATEWAY_USER@$GATEWAY_HOST" uname -m)"
case "$gateway_arch" in
  x86_64|amd64) gateway_asset='xconnect-gateway-linux-amd64'; xray_asset='Xray-linux-64.zip' ;;
  aarch64|arm64) gateway_asset='xconnect-gateway-linux-arm64'; xray_asset='Xray-linux-arm64-v8a.zip' ;;
  *) echo "Unsupported Gateway architecture: $gateway_arch" >&2; exit 1 ;;
esac
gateway_release_dir="$LAB_DIR/releases/gateway"
mkdir -p "$gateway_release_dir"
GH_TOKEN="$CLI_RELEASE_TOKEN" gh release download "$GATEWAY_RELEASE_TAG" \
  --repo ai-workspace-xstream/XConnect-Gateway \
  --pattern "$gateway_asset" --pattern SHA256SUMS \
  --dir "$gateway_release_dir" --clobber >/dev/null
awk -v asset="$gateway_asset" '$2 == asset || $2 == "dist/" asset {sub("dist/", "", $2); print}' \
  "$gateway_release_dir/SHA256SUMS" > "$gateway_release_dir/SHA256SUMS.selected"
[[ -s "$gateway_release_dir/SHA256SUMS.selected" ]] || { echo 'XConnect-Gateway release is missing its checksum' >&2; exit 1; }
(cd "$gateway_release_dir" && sha256sum -c SHA256SUMS.selected >/dev/null) || { echo 'XConnect-Gateway release checksum verification failed' >&2; exit 1; }
install -m 755 "$gateway_release_dir/$gateway_asset" "$gateway_binary"

GH_TOKEN="${GITHUB_TOKEN:-}" gh release download "$XRAY_RELEASE_TAG" \
  --repo XTLS/Xray-core \
  --pattern "$xray_asset" --pattern "$xray_asset.dgst" \
  --dir "$LAB_DIR/releases" --clobber >/dev/null
xray_expected="$(awk '$1 == "SHA2-256=" {print $2; exit}' "$LAB_DIR/releases/$xray_asset.dgst")"
xray_actual="$(sha256sum "$LAB_DIR/releases/$xray_asset" | awk '{print $1}')"
[[ "$xray_expected" =~ ^[0-9a-f]{64}$ && "$xray_expected" == "$xray_actual" ]] || { echo 'Xray release checksum verification failed' >&2; exit 1; }
unzip -p "$LAB_DIR/releases/$xray_asset" xray > "$xray_binary" || { echo 'Xray release archive is missing xray' >&2; exit 1; }
chmod 755 "$xray_binary"

"${gateway_scp[@]}" "$gateway_binary" "$xray_binary" "$gateway_tls_cert" "$gateway_tls_key" \
  "$GATEWAY_USER@$GATEWAY_HOST:/tmp/" >/dev/null
"${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" sudo bash -s -- "$ZERO_ACCOUNTS_API_URL" "$GATEWAY_RELEASE_TAG" <<'GATEWAY_RUNTIME_BOOTSTRAP'
set -euo pipefail
controller="$1"
gateway_release="$2"
install -d -m 700 /var/lib/xconnect-gateway /etc/xconnect-gateway
install -m 755 /tmp/xconnect-gateway /usr/local/bin/xconnect-gateway
install -d -m 755 /usr/local/lib/xconnect-gateway/bin
install -m 755 /tmp/xray /usr/local/lib/xconnect-gateway/xray
ln -sfn /usr/local/lib/xconnect-gateway/xray /usr/local/lib/xconnect-gateway/bin/xray
install -m 644 /tmp/gateway.tls.crt /etc/xconnect-gateway/tls.crt
install -m 600 /tmp/gateway.tls.key /etc/xconnect-gateway/tls.key
rm -f /tmp/xconnect-gateway /tmp/xray /tmp/gateway.tls.crt /tmp/gateway.tls.key
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl jq wireguard-tools >/dev/null
getent group caddy >/dev/null || {
  echo 'Shared Gateway frontend requires the Agent Proxy caddy group' >&2
  exit 1
}
install -d -o root -g caddy -m 0750 /run/xconnect-gateway
install -d -m 755 /etc/sysctl.d
printf '%s\n' 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-xconnect-gateway-forwarding.conf
sysctl -q -p /etc/sysctl.d/99-xconnect-gateway-forwarding.conf
[[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]]
cat >/etc/systemd/system/xconnect-gateway-xray.service <<'UNIT'
[Unit]
Description=XConnect Gateway VLESS runtime
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=caddy
RuntimeDirectory=xconnect-gateway
RuntimeDirectoryMode=0750
Environment=PATH=/usr/local/lib/xconnect-gateway/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/usr/local/lib/xconnect-gateway/xray run -config /var/lib/xconnect-gateway/runtime/xray.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/xconnect-gateway-sync.service <<'UNIT'
[Unit]
Description=Synchronize XConnect Gateway with XConnect Zero
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/xconnect-gateway up --state-dir /var/lib/xconnect-gateway --tls-cert /etc/xconnect-gateway/tls.crt --tls-key /etc/xconnect-gateway/tls.key
UNIT
cat >/etc/systemd/system/xconnect-gateway-sync.timer <<'UNIT'
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
systemctl daemon-reload
systemctl enable xconnect-gateway-xray.service >/dev/null
systemctl enable --now xconnect-gateway-sync.timer >/dev/null
PATH=/usr/local/lib/xconnect-gateway/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin /usr/local/bin/xconnect-gateway diagnose >/dev/null
if [[ ! -s /var/lib/xconnect-gateway/state.json ]]; then
  /usr/local/bin/xconnect-gateway init --state-dir /var/lib/xconnect-gateway --controller "$controller" --gateway-id gw-uat-tw-xconnect >/var/lib/xconnect-gateway/init.log
  chmod 600 /var/lib/xconnect-gateway/init.log
fi
printf '%s\n' "$gateway_release" >/etc/xconnect-gateway/release
GATEWAY_RUNTIME_BOOTSTRAP

gateway_public_key="$("${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" 'sudo jq -er .wireguard_public_key /var/lib/xconnect-gateway/state.json')"
[[ "$gateway_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'Gateway runtime did not generate a valid WireGuard public key' >&2; exit 1; }

echo 'Stage: issue a short-lived formal UAT invitation'
issue_invite() {
  local role="$1" device="$2" destination="$3"
  local request="$LAB_DIR/${role}-bootstrap.json"
  local response="$LAB_DIR/${role}-bootstrap-response.json"
  local expires_at
  expires_at="$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(minutes=15)).isoformat(timespec="seconds").replace("+00:00","Z"))')"
  jq -n \
    --arg owner "$ZERO_OWNER_EMAIL" --arg controller "$ZERO_ACCOUNTS_API_URL" \
    --arg network "$ZERO_NETWORK_ID" --arg gateway_id "gw-uat-tw-xconnect" \
    --arg gateway_key "$gateway_public_key" --arg gateway_host "$GATEWAY_SERVER_NAME" \
    --arg vless "$LAB_VLESS_ID" --arg device "$device" --arg role "$role" --arg expires "$expires_at" \
    --arg cidr "$overlay_cidr" --arg gateway_address "$gateway_address" \
    '{owner_email:$owner,bootstrap:{controller_url:$controller,network:{id:$network,display_name:"XConnect UAT network",cidr:$cidr,gateway_id:$gateway_id,gateway_wireguard_public_key:$gateway_key,gateway_wireguard_address:$gateway_address,gateway_endpoint_host:$gateway_host,gateway_endpoint_port:51820,transport_server_name:$gateway_host,transport_port:443,transport_auth_id:$vless},invite:{device_id:$device,platform:"linux",role:$role,expires_at:$expires}}}' \
    >"$request"
  local status
  status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    --config <(printf 'header = @%s\n' "$zero_header") \
    --data-binary "@$request" "$ZERO_ACCOUNTS_API_URL/api/internal/overlay/networks/bootstrap" || true)"
  [[ "$status" == 201 ]] || { echo "Formal Zero $role invitation bootstrap failed: HTTP $status" >&2; exit 1; }
  jq -e --arg network "$ZERO_NETWORK_ID" --arg device "$device" --arg expected_role "$role" \
    '.network.id == $network and .invite.network_id == $network and .invite.device_id == $device and .invite.role == $expected_role and .invite.platform == "linux" and .invite.remaining_uses == 1' \
    "$response" >/dev/null || { echo "Formal Zero $role invitation binding mismatch" >&2; exit 1; }
  jq -er '.join_uri' "$response" >"$destination"
  grep -Eq '^xconnect://join/' "$destination"
  chmod 600 "$destination"
}

gateway_credential_present="$("${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" 'sudo jq -r ".device_credential.credential // empty" /var/lib/xconnect-gateway/state.json')"
if [[ -z "$gateway_credential_present" ]]; then
  issue_invite gateway gw-uat-tw-xconnect "$gateway_invite"
  "${gateway_scp[@]}" "$gateway_invite" "$GATEWAY_USER@$GATEWAY_HOST:/tmp/xconnect-gateway.invite" >/dev/null
  "${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" sudo bash -s -- <<'GATEWAY_ENROLL'
set -euo pipefail
install -m 600 /tmp/xconnect-gateway.invite /var/lib/xconnect-gateway/join-uri
/usr/local/bin/xconnect-gateway join --state-dir /var/lib/xconnect-gateway --gateway-id gw-uat-tw-xconnect "$(cat /var/lib/xconnect-gateway/join-uri)"
rm -f /tmp/xconnect-gateway.invite /var/lib/xconnect-gateway/join-uri
GATEWAY_ENROLL
fi
"${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" \
  "sudo jq -e --arg network '$ZERO_NETWORK_ID' '.network_id == \$network and (.device_credential.credential | length) > 0' /var/lib/xconnect-gateway/state.json >/dev/null"

issue_invite one "$ONE_DEVICE_ID" "$invite"

echo 'Stage: enroll and synchronize the existing Linux One'
ansible_one_log="$LAB_DIR/ansible-one.log"
if ! ANSIBLE_HOST_KEY_CHECKING=True \
    VECTOR_AUTH_USER="$OBSERVABILITY_USER" \
    VECTOR_AUTH_PASSWORD="$OBSERVABILITY_PASSWORD" \
    OBSERVABILITY_ENDPOINT=https://observability.svc.plus \
    ansible-playbook -i "$ONE_HOST," "$GITHUB_WORKSPACE/playbooks/deploy_xconnect_one.yml" \
    --user "$ONE_USER" \
    --private-key "$one_key" \
    --become-password-file "$one_become_password" \
    --ssh-common-args="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" \
    --extra-vars "xconnect_one_hosts=all xconnect_one_enabled=true xconnect_one_environment=uat xconnect_one_state_dir=/var/lib/xconnect-one/uat xconnect_one_binary_source=$LAB_DIR/xconnect xconnect_one_device_id=$ONE_DEVICE_ID xconnect_one_device_name=observability-uat xconnect_one_expected_network_id=$ZERO_NETWORK_ID xconnect_one_invite_file_source=$invite xconnect_one_expected_overlay_cidr=$overlay_cidr xconnect_one_expected_wireguard_interface=xconone0 xconnect_one_expected_xray_loopback_port=18080 xconnect_one_sync_interval_seconds=300 xconnect_one_install_observability=true" \
    >"$ansible_one_log" 2>&1; then
  echo 'XConnect One Ansible deployment failed; sanitized task summary:' >&2
  perl -pe 's{xconnect://join/\S+}{xconnect://join/[REDACTED]}g; s{(?i)(password|token|private[_-]?key|secret)(\s*[:=]\s*)\S+}{$1$2[REDACTED]}g' \
    "$ansible_one_log" | grep -E 'TASK \[|fatal:|FAILED!|ERROR|msg:' | tail -n 80 >&2 || true
  exit 2
fi

echo 'Stage: reconcile the stable Gateway peer set'
"${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" \
  'sudo env PATH=/usr/local/lib/xconnect-gateway/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin xconnect-gateway up --state-dir /var/lib/xconnect-gateway --tls-cert /etc/xconnect-gateway/tls.crt --tls-key /etc/xconnect-gateway/tls.key' \
  >/dev/null

echo 'Stage: verify signed sync, runtime state and exact peer handshake'
status="$(one_sudo 'xconnect status --state-dir /var/lib/xconnect-one/uat')"
jq -e --arg device "$ONE_DEVICE_ID" --arg network "$ZERO_NETWORK_ID" \
  '.joined == true and .device_id == $device and .network_id == $network and .runtime.applied == true and .credential.present == true and .credential.expired == false' \
  <<<"$status" >/dev/null
one_public_key="$(one_sudo 'wg show xconone0 public-key')"
handshake="$(${gateway_ssh[@]} "$GATEWAY_USER@$GATEWAY_HOST" 'sudo wg show xconzero0 latest-handshakes')"
awk -v peer="$one_public_key" -v now="$(date +%s)" \
  '$1 == peer && $2 > 0 && now-$2 >= 0 && now-$2 < 180 {ok=1} END {exit !ok}' <<<"$handshake"

echo 'Stage: verify private ping and temporary private HTTP'
probe_dir="$(${gateway_ssh[@]} "$GATEWAY_USER@$GATEWAY_HOST" 'sudo mktemp -d /run/xconnect-one-uat-http.XXXXXX')"
probe_pid_file="$probe_dir/pid"
"${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" \
  "printf '%s\\n' xconnect-uat-private-http | sudo tee '$probe_dir/index.html' >/dev/null; sudo sh -c 'nohup python3 -m http.server 18081 --bind $gateway_wireguard_ip --directory \"$probe_dir\" >/dev/null 2>&1 & echo \$! > \"$probe_pid_file\"'"
"${one_ssh[@]}" "$ONE_USER@$ONE_HOST" "ping -c 3 -W 3 $gateway_wireguard_ip >/dev/null"
"${one_ssh[@]}" "$ONE_USER@$ONE_HOST" \
  "curl --fail --silent --show-error --noproxy '*' --max-time 10 http://$gateway_wireguard_ip:18081/ | grep -Fxq xconnect-uat-private-http"
echo "PASS: $ONE_DEVICE_ID joined UAT through $GATEWAY_SERVER_NAME; signed sync, exact handshake, private ping and HTTP succeeded."
