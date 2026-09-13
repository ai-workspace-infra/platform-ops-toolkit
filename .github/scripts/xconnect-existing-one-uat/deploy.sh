#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${GITHUB_WORKSPACE:?}"
: "${LAB_DIR:?}"
: "${CLI_RELEASE_TOKEN:?}"
: "${CLI_RELEASE_TAG:?}"
: "${ZERO_ACCOUNTS_API_URL:?}"
: "${ZERO_SERVICE_TOKEN:?}"
: "${ZERO_OWNER_EMAIL:?}"
: "${LAB_VLESS_ID:?}"
: "${ZERO_NETWORK_ID:?}"
: "${ONE_DEVICE_ID:?}"
: "${ONE_HOST:?}"
: "${ONE_USER:?}"
: "${ONE_SSH_PRIVATE_KEY_B64:?}"
: "${GATEWAY_HOST:?}"
: "${GATEWAY_USER:?}"
: "${GATEWAY_SSH_PRIVATE_KEY_B64:?}"
: "${GATEWAY_SERVER_NAME:?}"
: "${OBSERVABILITY_USER:?}"
: "${OBSERVABILITY_PASSWORD:?}"

mkdir -p "$LAB_DIR/releases"
known_hosts="$LAB_DIR/known_hosts"
one_key="$LAB_DIR/one.ssh"
gateway_key="$LAB_DIR/gateway.ssh"
zero_header="$LAB_DIR/zero.header"
invite="$LAB_DIR/one.invite"
probe_dir=''

cleanup() {
  if [[ -n "$probe_dir" ]]; then
    "${gateway_ssh[@]:-false}" "$GATEWAY_USER@$GATEWAY_HOST" \
      "sudo test -s '$probe_dir/pid' && sudo kill \"\$(sudo cat '$probe_dir/pid')\" 2>/dev/null || true; sudo rm -rf '$probe_dir'" \
      >/dev/null 2>&1 || true
  fi
  rm -f "$one_key" "$gateway_key" "$zero_header" "$invite" \
    "$LAB_DIR/xconnect" "$LAB_DIR/releases/SHA256SUMS" \
    "$LAB_DIR/releases/xconnect-linux-amd64" "$LAB_DIR/releases/xconnect-linux-arm64"
}
trap cleanup EXIT

printf '%s' "$ONE_SSH_PRIVATE_KEY_B64" | base64 --decode >"$one_key"
printf '%s' "$GATEWAY_SSH_PRIVATE_KEY_B64" | base64 --decode >"$gateway_key"
printf 'X-Service-Token: %s\nContent-Type: application/json\n' "$ZERO_SERVICE_TOKEN" >"$zero_header"
chmod 600 "$one_key" "$gateway_key" "$zero_header"

ssh-keyscan -H "$ONE_HOST" "$GATEWAY_HOST" >"$known_hosts" 2>/dev/null
test -s "$known_hosts" || { echo 'SSH host key discovery failed' >&2; exit 1; }

SSH_COMMON=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
one_ssh=(ssh -i "$one_key" "${SSH_COMMON[@]}")
gateway_ssh=(ssh -i "$gateway_key" "${SSH_COMMON[@]}")

echo 'Stage: verify the fixed UAT One declaration'
declaration="$GITHUB_WORKSPACE/gitops/vpn-overlay/uat/xconnect-one-nodes.yaml"
grep -Fq 'gateway_ref: TW-XConnect.svc.plus' "$declaration"
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

echo 'Stage: issue a short-lived formal UAT invitation'
gateway_public_key="$("${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" 'sudo jq -er .wireguard_public_key /var/lib/xconnect-gateway/state.json')"
[[ "$gateway_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]
bootstrap_request="$LAB_DIR/bootstrap.json"
bootstrap_response="$LAB_DIR/bootstrap-response.json"
expires_at="$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(minutes=15)).isoformat(timespec="seconds").replace("+00:00","Z"))')"
jq -n \
  --arg owner "$ZERO_OWNER_EMAIL" --arg controller "$ZERO_ACCOUNTS_API_URL" \
  --arg network "$ZERO_NETWORK_ID" --arg gateway_id "gw-uat-tw-xconnect" \
  --arg gateway_key "$gateway_public_key" --arg gateway_host "$GATEWAY_SERVER_NAME" \
  --arg vless "$LAB_VLESS_ID" --arg device "$ONE_DEVICE_ID" --arg expires "$expires_at" \
  '{owner_email:$owner,bootstrap:{controller_url:$controller,network:{id:$network,display_name:"XConnect UAT network",cidr:"10.77.0.0/24",gateway_id:$gateway_id,gateway_wireguard_public_key:$gateway_key,gateway_wireguard_address:"10.77.0.1/32",gateway_endpoint_host:$gateway_host,gateway_endpoint_port:51820,transport_server_name:$gateway_host,transport_port:443,transport_auth_id:$vless},invite:{device_id:$device,platform:"linux",role:"one",expires_at:$expires}}}' \
  >"$bootstrap_request"
status="$(curl --silent --show-error --output "$bootstrap_response" --write-out '%{http_code}' \
  --config <(printf 'header = @%s\n' "$zero_header") \
  --data-binary "@$bootstrap_request" "$ZERO_ACCOUNTS_API_URL/api/internal/overlay/networks/bootstrap" || true)"
[[ "$status" == 201 ]] || { echo "Formal Zero invitation bootstrap failed: HTTP $status" >&2; exit 1; }
jq -er '.join_uri' "$bootstrap_response" >"$invite"
grep -Eq '^xconnect://join/' "$invite"
chmod 600 "$invite"

echo 'Stage: enroll and synchronize the existing Linux One'
ANSIBLE_HOST_KEY_CHECKING=True \
  VECTOR_AUTH_USER="$OBSERVABILITY_USER" \
  VECTOR_AUTH_PASSWORD="$OBSERVABILITY_PASSWORD" \
  OBSERVABILITY_ENDPOINT=https://observability.svc.plus \
  ansible-playbook -i "$ONE_HOST," "$GITHUB_WORKSPACE/playbooks/deploy_xconnect_one.yml" \
  --user "$ONE_USER" \
  --private-key "$one_key" \
  --ssh-common-args="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" \
  --extra-vars "xconnect_one_hosts=all xconnect_one_enabled=true xconnect_one_environment=uat xconnect_one_state_dir=/var/lib/xconnect-one/uat xconnect_one_binary_source=$LAB_DIR/xconnect xconnect_one_device_id=$ONE_DEVICE_ID xconnect_one_device_name=observability-uat xconnect_one_invite_file_source=$invite xconnect_one_expected_overlay_cidr=10.77.0.0/24 xconnect_one_expected_wireguard_interface=xconone0 xconnect_one_expected_xray_loopback_port=18080 xconnect_one_sync_interval_seconds=300 xconnect_one_install_observability=true" \
  >/dev/null

echo 'Stage: reconcile the stable Gateway peer set'
"${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" \
  'sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway --tls-cert /etc/xconnect-gateway/tls.crt --tls-key /etc/xconnect-gateway/tls.key' \
  >/dev/null

echo 'Stage: verify signed sync, runtime state and exact peer handshake'
status="$(${one_ssh[@]} "$ONE_USER@$ONE_HOST" 'sudo xconnect status --state-dir /var/lib/xconnect-one/uat')"
jq -e --arg device "$ONE_DEVICE_ID" --arg network "$ZERO_NETWORK_ID" \
  '.joined == true and .device_id == $device and .network_id == $network and .runtime.applied == true and .credential.present == true and .credential.expired == false' \
  <<<"$status" >/dev/null
one_public_key="$(${one_ssh[@]} "$ONE_USER@$ONE_HOST" 'sudo wg show xconone0 public-key')"
handshake="$(${gateway_ssh[@]} "$GATEWAY_USER@$GATEWAY_HOST" 'sudo wg show xconzero0 latest-handshakes')"
awk -v peer="$one_public_key" -v now="$(date +%s)" \
  '$1 == peer && $2 > 0 && now-$2 >= 0 && now-$2 < 180 {ok=1} END {exit !ok}' <<<"$handshake"

echo 'Stage: verify private ping and temporary private HTTP'
probe_dir="$(${gateway_ssh[@]} "$GATEWAY_USER@$GATEWAY_HOST" 'sudo mktemp -d /run/xconnect-one-uat-http.XXXXXX')"
probe_pid_file="$probe_dir/pid"
"${gateway_ssh[@]}" "$GATEWAY_USER@$GATEWAY_HOST" \
  "printf '%s\\n' xconnect-uat-private-http | sudo tee '$probe_dir/index.html' >/dev/null; sudo sh -c 'nohup python3 -m http.server 18081 --bind 10.77.0.1 --directory \"$probe_dir\" >/dev/null 2>&1 & echo \$! > \"$probe_pid_file\"'"
"${one_ssh[@]}" "$ONE_USER@$ONE_HOST" 'ping -c 3 -W 3 10.77.0.1 >/dev/null'
"${one_ssh[@]}" "$ONE_USER@$ONE_HOST" \
  "curl --fail --silent --show-error --noproxy '*' --max-time 10 http://10.77.0.1:18081/ | grep -Fxq xconnect-uat-private-http"
echo "PASS: $ONE_DEVICE_ID joined UAT through $GATEWAY_SERVER_NAME; signed sync, exact handshake, private ping and HTTP succeeded."
