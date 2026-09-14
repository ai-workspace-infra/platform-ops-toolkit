#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${GITHUB_WORKSPACE:?}"
LAB_DIR="${LAB_DIR:?}"
DECL="$ROOT/gitops/vpn-overlay/uat/xconnect-lab.json"
gateway=$(jq -er .gateway_ip.value "$LAB_DIR/outputs.json")
gateway_transport=$(jq -er .gateway_transport_ip.value "$LAB_DIR/outputs.json")
gateway_private=$(jq -er .gateway_private_ip.value "$LAB_DIR/outputs.json")
gateway_user_default=$(jq -er .gateway_ssh_user.value "$LAB_DIR/outputs.json")
gateway_user="${EXTERNAL_GATEWAY_USER:-$gateway_user_default}"
client=$(jq -er .client_ip.value "$LAB_DIR/outputs.json")
client_user=$(jq -er .client_ssh_user.value "$LAB_DIR/outputs.json")
formal_zero=$(jq -er .zero_accounts_api_url.value "$LAB_DIR/outputs.json")
formal_portal=$(jq -er .zero_portal_url.value "$LAB_DIR/outputs.json")
base_network_id=$(jq -er .spec.overlay.network_id "$DECL")
overlay_cidr=$(jq -er .spec.overlay.cidr "$DECL")
gateway_address="${GATEWAY_WIREGUARD_ADDRESS:-$(jq -er .spec.overlay.gateway_address "$DECL")}"
gateway_wireguard_ip="${gateway_address%/*}"
client_address=$(jq -er .spec.overlay.device_address "$DECL")
client_wireguard_ip="${client_address%/*}"
run_id=$(<"$LAB_DIR/run-id")
gateway_provider=$(jq -er .gateway_provider.value "$LAB_DIR/outputs.json")
transport_profile=$(jq -er .spec.overlay.transport_profile "$DECL")
xhttp_path=$(jq -er .path <<<"$transport_profile")
xhttp_mode=$(jq -er .mode <<<"$transport_profile")
xhttp_host=$(jq -er .host <<<"$transport_profile")
if [[ "$gateway_provider" == external ]]; then
  network_id="${EXTERNAL_NETWORK_ID:?EXTERNAL_NETWORK_ID is required for an external Gateway}"
  gateway_id="${EXTERNAL_GATEWAY_ID:?EXTERNAL_GATEWAY_ID is required for an external Gateway}"
  transport_server_name="${EXTERNAL_GATEWAY_SERVER_NAME:?EXTERNAL_GATEWAY_SERVER_NAME is required for an external Gateway}"
else
  network_id="${base_network_id}-${run_id}"
  gateway_id="gw-${run_id}"
  # The dynamic endpoint is addressed by IP, while this SNI is covered by the
  # Vault wildcard certificate for svc.plus.
  transport_server_name="${XCONNECT_GATEWAY_SERVER_NAME:-xconnect-lab.svc.plus}"
fi
client_id="one-${run_id}"
CLIENT_SSH=(-i "$LAB_DIR/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
if [[ "$gateway_provider" == external ]]; then
  GATEWAY_SSH=(-i "${EXTERNAL_GATEWAY_SSH_KEY:?EXTERNAL_GATEWAY_SSH_KEY is required for an external Gateway}" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
  GATEWAY_SCP=(scp -i "${EXTERNAL_GATEWAY_SSH_KEY:?EXTERNAL_GATEWAY_SSH_KEY is required for an external Gateway}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
else
  GATEWAY_SSH=("${CLIENT_SSH[@]}")
  GATEWAY_SCP=(scp -i "$LAB_DIR/id_ed25519" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")
fi
CLIENT_SCP=(scp -i "$LAB_DIR/id_ed25519" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$LAB_DIR/known_hosts")

# The disposable Linux One and Gateway share the UAT VPC. Keep the public
# 443 endpoint for optional desktop handoff, but make the cloud client use the
# Gateway private address so it does not hairpin through the Internet Gateway.
# The transport remains VLESS/XHTTP over TCP 443; only the AWS path is private.
client_transport_endpoint="$gateway_transport"
if [[ "$gateway_provider" != external ]]; then
  client_transport_endpoint="$gateway_private"
fi

wait_for_ssh() {
  local user="$1" host="$2" ready=false
  for attempt in {1..60}; do
    if ssh "${CLIENT_SSH[@]}" "$user@$host" true 2>/dev/null; then ready=true; break; fi
    sleep 5
  done
  "$ready" || { echo "SSH bootstrap unavailable for $user@$host"; exit 1; }
  ssh "${CLIENT_SSH[@]}" "$user@$host" 'sudo cloud-init status --wait >/dev/null 2>&1; sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools curl ca-certificates python3 openssl iproute2 jq >/dev/null 2>&1'
}

prepare_runtime() {
if [[ "$gateway_provider" != external ]]; then
  wait_for_ssh "$gateway_user" "$gateway"
fi
wait_for_ssh "$client_user" "$client"

mkdir -p "$LAB_DIR/tls" "$LAB_DIR/invites"
: "${XCONNECT_GATEWAY_TLS_FULLCHAIN_PEM_B64:?Gateway TLS fullchain was not supplied by Vault}"
: "${XCONNECT_GATEWAY_TLS_KEY_PEM_B64:?Gateway TLS private key was not supplied by Vault}"
gateway_trust_bundle_b64="${XCONNECT_GATEWAY_TLS_TRUST_BUNDLE_PEM_B64:-${XCONNECT_GATEWAY_TLS_CA_PEM_B64:-}}"
: "${gateway_trust_bundle_b64:?Gateway trust bundle was not supplied by Vault}"
printf '%s' "$XCONNECT_GATEWAY_TLS_FULLCHAIN_PEM_B64" | base64 --decode > "$LAB_DIR/tls/server.crt"
printf '%s' "$XCONNECT_GATEWAY_TLS_KEY_PEM_B64" | base64 --decode > "$LAB_DIR/tls/server.key"
printf '%s' "$gateway_trust_bundle_b64" | base64 --decode > "$LAB_DIR/tls/ca.crt"
chmod 600 "$LAB_DIR/tls/server.key"
chmod 644 "$LAB_DIR/tls/server.crt" "$LAB_DIR/tls/ca.crt"
openssl x509 -in "$LAB_DIR/tls/server.crt" -noout >/dev/null
openssl pkey -in "$LAB_DIR/tls/server.key" -noout >/dev/null
openssl x509 -in "$LAB_DIR/tls/ca.crt" -noout >/dev/null
openssl x509 -in "$LAB_DIR/tls/server.crt" -checkhost "$transport_server_name" -noout >/dev/null
server_key_digest=$(openssl x509 -in "$LAB_DIR/tls/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
private_key_digest=$(openssl pkey -in "$LAB_DIR/tls/server.key" -pubout -outform DER | sha256sum | awk '{print $1}')
[[ "$server_key_digest" == "$private_key_digest" ]] || { echo 'Vault Gateway TLS certificate/private key mismatch'; exit 1; }
if [[ "$gateway_provider" == external ]]; then
  gateway_public_key=$(ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" 'sudo jq -er .wireguard_public_key /var/lib/xconnect-gateway/state.json')
  [[ "$gateway_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'External Gateway returned an invalid WireGuard public key'; exit 1; }
  external_gateway_binding=$(ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" 'sudo jq -cer "{gateway_id,network_id}" /var/lib/xconnect-gateway/state.json')
  expected_gateway_binding=$(jq -cn --arg gateway "$gateway_id" --arg network "$network_id" '{gateway_id:$gateway,network_id:$network}')
  [[ "$external_gateway_binding" == "$expected_gateway_binding" ]] || {
    echo 'External Gateway identity is not bound to the requested Zero network'
    exit 1
  }
  printf '%s\n' "$gateway_public_key" > "$LAB_DIR/gateway-public-key"
else
  : # Both Gateway modes use the Vault domain certificate.
fi

echo 'Stage: formal Zero readiness'
status=$(curl --silent --show-error --output "$LAB_DIR/zero-readiness.json" --write-out '%{http_code}' \
  -H "X-Service-Token: $ZERO_SERVICE_TOKEN" -H 'Content-Type: application/json' \
  --data-binary '{}' "$formal_zero/api/internal/overlay/networks/bootstrap" || true)
[[ "$status" == 400 ]] || { echo "Formal Zero bootstrap endpoint is unavailable: HTTP $status"; exit 1; }
curl --fail --silent --show-error --output /dev/null "${formal_portal%/panel/xconnect-zero}/panel/xconnect-zero"

echo 'Stage: Gateway runtime bootstrap'
if [[ "$gateway_provider" != external ]]; then
"${GATEWAY_SCP[@]}" "$LAB_DIR/bin/xconnect-gateway" "$LAB_DIR/bin/xray" "$LAB_DIR/tls/server.key" "$LAB_DIR/tls/server.crt" "$LAB_DIR/tls/ca.crt" "$ROOT/.github/scripts/xconnect-lab/gateway.sh" "$gateway_user@$gateway:/tmp/" >/dev/null
ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" "sudo bash /tmp/gateway.sh '$gateway_transport' '$run_id' '$formal_zero' '$formal_portal' '$network_id' '$gateway_id' '$gateway_address'"
gateway_public_key=$(ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" 'sudo cat /opt/xconnect-lab/gateway.pub')
fi
[[ "$gateway_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'Gateway returned an invalid WireGuard public key'; exit 1; }
printf '%s\n' "$gateway_public_key" > "$LAB_DIR/gateway-public-key"

# One must consume the Gateway trust root, not a runner-local or One-generated
# trust root. For an AWS-owned Gateway, obtain the public CA from the node that
# just installed it. The external persistent Gateway is managed outside this
# lab and must not be changed just to expose an experiment-specific file; in
# that mode the same public trust bundle is sourced from Vault and the live
# Gateway TLS endpoint is verified from the actual One data-plane path before
# the trust bundle is handed to One.
gateway_ca_handoff="$LAB_DIR/tls/gateway-ca.crt"
gateway_ca_tmp="$gateway_ca_handoff.tmp"
if [[ "$gateway_provider" == external ]]; then
  # The external Gateway is an independently managed production-owned host.
  # Do not require an implementation-specific CA file on it or mutate its
  # filesystem. The trust bundle is public material already read from the
  # Vault domain record. Do not probe the endpoint from the runner here: the
  # persistent Gateway intentionally restricts 443 to controlled-node sources,
  # while the runner is not necessarily one of them. The Linux One verification
  # below performs the authoritative TLS/SNI check from the actual data-plane
  # node before asserting WireGuard handshake and private connectivity.
  install -m 644 "$LAB_DIR/tls/ca.crt" "$gateway_ca_handoff"
else
  rm -f "$gateway_ca_tmp"
  ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" \
    'if sudo test -s /etc/xconnect-gateway/ca.crt; then sudo cat /etc/xconnect-gateway/ca.crt; elif sudo test -s /usr/local/share/ca-certificates/xconnect-lab.crt; then sudo cat /usr/local/share/ca-certificates/xconnect-lab.crt; else exit 1; fi' > "$gateway_ca_tmp" \
    || { rm -f "$gateway_ca_tmp"; echo 'Gateway did not expose its public CA handoff'; exit 1; }
  cmp -s "$LAB_DIR/tls/ca.crt" "$gateway_ca_tmp" || { rm -f "$gateway_ca_tmp"; echo 'Gateway CA handoff differs from Vault domain trust bundle'; exit 1; }
  mv "$gateway_ca_tmp" "$gateway_ca_handoff"
fi
chmod 644 "$gateway_ca_handoff"
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
    --arg endpoint "$client_transport_endpoint" --arg gateway_address "$gateway_address" --arg cidr "$overlay_cidr" --arg vless "$LAB_VLESS_ID" \
    --arg role "$role" --arg device "$device_id" --arg expires "$expires" --arg server_name "$transport_server_name" \
    '{owner_email:$owner,bootstrap:{controller_url:$controller,network:{id:$network,display_name:"XConnect UAT Gateway network",cidr:$cidr,gateway_id:$gateway_id,gateway_wireguard_public_key:$gateway_key,gateway_wireguard_address:$gateway_address,gateway_endpoint_host:$endpoint,gateway_endpoint_port:51820,transport_server_name:$server_name,transport_port:443,transport_auth_id:$vless,transport_kind:"vless-xhttp",transport_path:"/xconnect",transport_mode:"auto",transport_host:$server_name},invite:{device_id:$device,platform:"linux",role:$role,expires_at:$expires}}}' > "$request"
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
if [[ "$gateway_provider" != external ]]; then
  create_invite gateway "$gateway_id" "$LAB_DIR/invites/gateway"
fi
create_invite one "$client_id" "$LAB_DIR/invites/one"
}

enroll_gateway() {
if [[ "$gateway_provider" == external ]]; then
  echo 'Stage: external persistent Gateway already enrolled; skipping re-enrollment'
  return
fi
echo 'Stage: formal Gateway enrollment and apply'
"${GATEWAY_SCP[@]}" "$LAB_DIR/invites/gateway" "$gateway_user@$gateway:/tmp/gateway-invite" >/dev/null
ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" "set -eu; sudo install -m 600 /tmp/gateway-invite /opt/xconnect-lab/gateway-invite; sudo sh -c 'xconnect-gateway join --state-dir /var/lib/xconnect-gateway --gateway-id \"$gateway_id\" \"\$(cat /opt/xconnect-lab/gateway-invite)\"'; sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway --tls-cert /etc/xconnect-gateway/tls.crt --tls-key /etc/xconnect-gateway/tls.key"
}

enroll_one() {
echo 'Stage: controlled-client formal enrollment and apply'
local playbook="$ROOT/playbooks/deploy_xconnect_one.yml"
test -f "$playbook" || { echo 'Reviewed playbooks revision does not contain the XConnect One entrypoint'; exit 1; }

# The dynamic client is deliberately delivered through the canonical host role.
# The role owns runtime bootstrap, short-lived invite staging, join, sync,
# service timer and preflight; this workflow only supplies the reviewed
# artifact and run-scoped values. The variable file is runner-private and is
# removed after Ansible returns.
local variables_file="$LAB_DIR/xconnect-one-vars.json"
local ca_source=""
if [[ "$gateway_provider" != external ]]; then
  ca_source="$LAB_DIR/tls/gateway-ca.crt"
  test -s "$ca_source" || { echo 'Gateway CA handoff is required before One deployment'; exit 1; }
fi
jq -n \
  --arg binary "$LAB_DIR/bin/xconnect" \
  --arg ca "$ca_source" \
  --arg invite "$LAB_DIR/invites/one" \
  --arg state_dir "/var/lib/xconnect-one" \
  --arg device "$client_id" \
  --arg network "$network_id" \
  --arg cidr "$overlay_cidr" \
  '{xconnect_one_hosts:"all",xconnect_one_enabled:true,xconnect_one_environment:"uat",
    xconnect_one_state_dir:$state_dir,xconnect_one_binary_source:$binary,
    xconnect_one_ca_certificate_source:$ca,
    xconnect_one_device_id:$device,xconnect_one_device_name:"uat-linux-one",
    xconnect_one_expected_network_id:$network,xconnect_one_invite_file_source:$invite,
    xconnect_one_expected_overlay_cidr:$cidr,xconnect_one_expected_wireguard_interface:"xconone0",
    xconnect_one_expected_xray_loopback_port:51830,xconnect_one_sync_interval_seconds:300,
    xconnect_one_install_observability:false}' > "$variables_file"

local ansible_status=0
ANSIBLE_HOST_KEY_CHECKING=True \
  ansible-playbook -i "${client}," "$playbook" \
    --user "$client_user" --private-key "$LAB_DIR/id_ed25519" \
    --ssh-common-args="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$LAB_DIR/known_hosts" \
    --extra-vars "@$variables_file" || ansible_status=$?
rm -f "$variables_file"
(( ansible_status == 0 )) || exit "$ansible_status"

# One enrollment advances the centralized generation. Reconcile the Gateway so
# its WireGuard peer set contains the newly registered controlled client.
ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" 'sudo xconnect-gateway up --state-dir /var/lib/xconnect-gateway --tls-cert /etc/xconnect-gateway/tls.crt --tls-key /etc/xconnect-gateway/tls.key'
if [[ "$gateway_provider" != external ]]; then
  # The private HTTP probe binds to the Gateway WireGuard address, so start it
  # only after xconnect-gateway has created the interface and applied peers.
  ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" 'sudo systemctl enable --now xconnect-lab-http.service'
fi
}

deploy_observability() {
  echo 'Stage: register Gateway and One base metrics with central Observability'
  : "${OBSERVABILITY_ENDPOINT:?OBSERVABILITY_ENDPOINT is required}"
  : "${OBSERVABILITY_QUERY_PATH:?OBSERVABILITY_QUERY_PATH is required}"
  : "${OBSERVABILITY_ENVIRONMENT:?OBSERVABILITY_ENVIRONMENT is required}"
  : "${OBSERVABILITY_USER:?OBSERVABILITY_USER is required}"
  : "${OBSERVABILITY_PASSWORD:?OBSERVABILITY_PASSWORD is required}"
  local playbook="$ROOT/playbooks/deploy_xconnect_observability.yml"
  test -f "$playbook" || { echo 'Reviewed playbooks revision does not contain the XConnect observability entrypoint'; exit 1; }

  deploy_node_observability() {
    local host="$1" user="$2" key="$3" role="$4" interface="$5" state_dir="$6" instance="$7"
    ANSIBLE_HOST_KEY_CHECKING=True \
      VECTOR_AUTH_USER="$OBSERVABILITY_USER" \
      VECTOR_AUTH_PASSWORD="$OBSERVABILITY_PASSWORD" \
      OBSERVABILITY_ENDPOINT="$OBSERVABILITY_ENDPOINT" \
      ansible-playbook -i "${host}," "$playbook" \
        --user "$user" --private-key "$key" \
        --ssh-common-args="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$LAB_DIR/known_hosts" \
        --extra-vars "xconnect_observability_hosts=all xconnect_observability_role=$role xconnect_observability_environment=$OBSERVABILITY_ENVIRONMENT xconnect_observability_instance=$instance xconnect_observability_wireguard_interface=$interface xconnect_observability_state_dir=$state_dir"
  }

  local gateway_key="$LAB_DIR/id_ed25519"
  if [[ "$gateway_provider" == external ]]; then gateway_key="${EXTERNAL_GATEWAY_SSH_KEY:?EXTERNAL_GATEWAY_SSH_KEY is required}"; fi
  deploy_node_observability "$gateway" "$gateway_user" "$gateway_key" gateway xconzero0 /var/lib/xconnect-gateway "$gateway_id"
  deploy_node_observability "$client" "$client_user" "$LAB_DIR/id_ed25519" one xconone0 /var/lib/xconnect-one "$client_id"

  check_node_collector() {
    local ssh_key="$1" user="$2" host="$3" role="$4" instance="$5"
    ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$LAB_DIR/known_hosts" "$user@$host" \
      "sudo systemctl is-active --quiet xconnect-node-exporter vector xconnect-observability-collector.timer && sudo test -s /var/lib/xconnect-node-exporter/xconnect.prom && sudo grep -Fq 'xconnect_runtime_info{role=\"$role\",environment=\"$OBSERVABILITY_ENVIRONMENT\",instance=\"$instance\"}' /var/lib/xconnect-node-exporter/xconnect.prom"
  }
  check_node_collector "$gateway_key" "$gateway_user" "$gateway" gateway "$gateway_id"
  check_node_collector "$LAB_DIR/id_ed25519" "$client_user" "$client" one "$client_id"

  query_metric() {
    local role="$1" instance="$2" query result_file
    query="xconnect_runtime_info{role=\"${role}\",environment=\"${OBSERVABILITY_ENVIRONMENT}\",instance=\"${instance}\"}"
    result_file="$LAB_DIR/observability-${role}.json"
    for attempt in {1..12}; do
      if curl --fail --silent --show-error --user "$OBSERVABILITY_USER:$OBSERVABILITY_PASSWORD" --get \
        --data-urlencode "query=$query" "${OBSERVABILITY_ENDPOINT%/}${OBSERVABILITY_QUERY_PATH}" -o "$result_file" \
        && jq -e '.status == "success" and (.data.result | length) > 0' "$result_file" >/dev/null; then
        return 0
      fi
      sleep 10
    done
    echo "Observability did not return base metrics for ${role}/${instance}" >&2
    return 1
  }
  query_metric gateway "$gateway_id"
  query_metric one "$client_id"
  rm -f "$LAB_DIR/observability-gateway.json" "$LAB_DIR/observability-one.json"
  echo 'PASS: Gateway and One base metrics are visible through the central VictoriaMetrics query endpoint and Grafana datasource.'
}

verify_overlay() {
echo 'Stage: formal control plane and two-node data-plane verification'
gateway_public_key=$(<"$LAB_DIR/gateway-public-key")
if ! client_public_key=$(ssh "${CLIENT_SSH[@]}" "$client_user@$client" 'sudo wg show xconone0 public-key'); then
  echo 'Linux One verification failed: xconone0/public-key is unavailable; collecting safe runtime diagnostics.'
  ssh "${CLIENT_SSH[@]}" "$client_user@$client" sudo bash -s <<'CLIENT_EARLY_FAILURE_DIAGNOSTICS' || true
set -euo pipefail
if ip link show xconone0 >/dev/null 2>&1; then echo 'wireguard_interface=active'; else echo 'wireguard_interface=inactive'; fi
if pgrep -x xray >/dev/null; then echo 'xray_process=active'; else echo 'xray_process=inactive'; fi
if ss -lun | grep -Eq '127\.0\.0\.1:51830[[:space:]]'; then echo 'xray_loopback_udp=active'; else echo 'xray_loopback_udp=inactive'; fi
sudo xconnect status --state-dir /var/lib/xconnect-one 2>/dev/null | jq -c '{joined,device_id,network_id,generations,runtime,credential: {present: .credential.present, expired: .credential.expired}}' || true
sudo xconnect diagnose --state-dir /var/lib/xconnect-one 2>/dev/null | jq -c '[.[] | {code,healthy}]' || true
CLIENT_EARLY_FAILURE_DIAGNOSTICS
  exit 1
fi
[[ "$client_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'One returned an invalid WireGuard public key'; exit 1; }
if ! ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$run_id" "$gateway_provider" <<'GATEWAY_VERIFY'
set -euo pipefail
if [[ "$2" == external ]]; then
  [[ ! -e /etc/xconnect-lab/node-role ]] || [[ "$(cat /etc/xconnect-lab/node-role)" == relay ]]
else
  [[ "$(cat /etc/xconnect-lab/node-role)" == relay ]]
  [[ "$(cat /etc/xconnect-lab/lab-run)" == "$1" ]]
  systemctl is-active --quiet xconnect-lab-http.service
fi
systemctl is-active --quiet xconnect-gateway-xray.service
wg show xconzero0 >/dev/null
ss -ltn | grep -Eq ':443[[:space:]]'
xconnect-gateway status --state-dir /var/lib/xconnect-gateway
GATEWAY_VERIFY
then
  echo 'Gateway verification failed; collecting public runtime health only.'
  ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s <<'GATEWAY_EARLY_FAILURE_DIAGNOSTICS' || true
set -euo pipefail
if systemctl is-active --quiet xconnect-gateway-xray.service; then echo 'gateway_xray_process=active'; else echo 'gateway_xray_process=inactive'; fi
if systemctl is-active --quiet xconnect-lab-http.service; then echo 'gateway_http_service=active'; else echo 'gateway_http_service=inactive'; fi
if ss -ltn | grep -Eq ':443[[:space:]]'; then echo 'gateway_xray_listener=active'; else echo 'gateway_xray_listener=inactive'; fi
if ip link show xconzero0 >/dev/null 2>&1; then echo 'gateway_wireguard_interface=active'; else echo 'gateway_wireguard_interface=inactive'; fi
GATEWAY_EARLY_FAILURE_DIAGNOSTICS
  exit 1
fi
ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- \
  gateway /var/lib/xconnect-gateway/runtime/xray.json - "$transport_server_name" "$xhttp_path" "$xhttp_mode" "$xhttp_host" \
  < "$ROOT/.github/scripts/xconnect-lab/verify-xhttp-runtime.sh"

# The persistent external Gateway is not a lab-owned application host. For
# the private HTTP assertion only, expose a run-scoped marker on its existing
# WireGuard address and remove it on every exit path. This does not create a
# public listener or leave a service behind.
probe_pid_file=''
if [[ "$gateway_provider" == external ]]; then
  probe_pid_file="/run/xconnect-one-${run_id}.pid"
  ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$run_id" "$probe_pid_file" "$gateway_wireguard_ip" <<'START_PRIVATE_PROBE'
set -euo pipefail
run_id="$1"
pid_file="$2"
gateway_wireguard_ip="$3"
probe_dir="/run/xconnect-one-${run_id}"
sudo rm -rf "$probe_dir"
sudo install -d -m 755 "$probe_dir"
printf '%s\n' "$run_id" | sudo tee "$probe_dir/index.html" >/dev/null
sudo sh -c "nohup python3 -m http.server 8080 --bind '$gateway_wireguard_ip' --directory '$probe_dir' >/run/xconnect-one-${run_id}.log 2>&1 & echo \$! > '$pid_file'"
for attempt in {1..10}; do
  sudo ss -ltn | grep -Eq ':8080[[:space:]]' && exit 0
  sleep 1
done
echo 'private HTTP probe did not start' >&2
exit 1
START_PRIVATE_PROBE
  cleanup_private_probe() {
    ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$run_id" "$probe_pid_file" <<'STOP_PRIVATE_PROBE' || true
set -euo pipefail
run_id="$1"
pid_file="$2"
if [[ -s "$pid_file" ]]; then
  pid=$(sudo cat "$pid_file" || true)
  [[ "$pid" =~ ^[0-9]+$ ]] && sudo kill "$pid" 2>/dev/null || true
fi
sudo rm -f "$pid_file" "/run/xconnect-one-${run_id}.log"
sudo rm -rf "/run/xconnect-one-${run_id}"
STOP_PRIVATE_PROBE
  }
  trap cleanup_private_probe EXIT
fi

gateway_ca_sha256='system-public-ca'
if [[ "$gateway_provider" != external ]]; then
  gateway_ca_sha256=$(sha256sum "$LAB_DIR/tls/gateway-ca.crt" | awk '{print $1}')
fi
if ! ssh "${CLIENT_SSH[@]}" "$client_user@$client" sudo bash -s -- "$run_id" "$client_transport_endpoint" "$gateway_public_key" "$client_id" "$network_id" "$transport_server_name" "$gateway_wireguard_ip" "$gateway_ca_sha256" <<'CLIENT_VERIFY'
set -euo pipefail
client_failure() {
  echo "Client verification failed: $1"
  xconnect diagnose --state-dir /var/lib/xconnect-one 2>/dev/null \
    | jq -c '[.[] | {code,healthy}]' || true
  if pgrep -x xray >/dev/null; then echo 'xray_process=active'; else echo 'xray_process=inactive'; fi
  if ss -lun | grep -Eq '127\.0\.0\.1:51830[[:space:]]'; then echo 'xray_loopback_udp=active'; else echo 'xray_loopback_udp=inactive'; fi
  if ip link show xconone0 >/dev/null 2>&1; then echo 'wireguard_interface=active'; else echo 'wireguard_interface=inactive'; fi
  handshake_age=$(wg show xconone0 latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2 > 0 {age=now-$2} END {print age=="" ? "none" : age}')
  echo "wireguard_handshake_age_seconds=$handshake_age"
  exit 1
}
[[ "$(cat /etc/xconnect-lab/node-role)" == controlled-client ]] || client_failure role
tls_ca_file=/etc/ssl/certs/ca-certificates.crt
if [[ "$8" != system-public-ca ]]; then
  tls_ca_file=/usr/local/share/ca-certificates/xconnect-one-uat.crt
  [[ -r "$tls_ca_file" ]] || client_failure tls-ca-not-installed
  [[ "$(sha256sum "$tls_ca_file" | awk '{print $1}')" == "$8" ]] || client_failure tls-ca-handoff
fi
tls_verify=$(timeout 10 openssl s_client -connect "$2:443" -servername "$6" -verify_hostname "$6" \
  -CAfile "$tls_ca_file" -verify_return_error </dev/null 2>/dev/null \
  | awk '/Verify return code:/ {print $4; exit}' || true)
[[ "$tls_verify" == 0 ]] || client_failure tls-trust-or-transport
connected=0
for attempt in {1..30}; do
  if ping -c 1 -W 2 "$7" >/dev/null 2>&1 && curl --fail --max-time 5 --noproxy '*' -s "http://$7:8080/" | grep -Fxq "$1"; then connected=1; break; fi
  sleep 2
done
[[ "$connected" == 1 ]] || client_failure private-ping-http
pgrep -x xray >/dev/null || client_failure xray-process
wg show xconone0 latest-handshakes | awk -v peer="$3" -v now="$(date +%s)" '$1 == peer && $2 > 0 && now-$2 >= 0 && now-$2 < 180 {ok=1} END {exit !ok}' || client_failure wireguard-handshake
xconnect sync --state-dir /var/lib/xconnect-one >/dev/null || client_failure config-sync
xconnect status --state-dir /var/lib/xconnect-one | jq -e --arg device "$4" --arg network "$5" \
  '.joined == true and .device_id == $device and .network_id == $network and .generations.state > 0 and .runtime.applied == true and .runtime.core_id == "xray" and .credential.present == true and .credential.expired == false' \
  >/dev/null || client_failure signed-config-ack-status
curl --fail --max-time 10 --noproxy '*' -s "http://$7:8080/" | grep -Fxq "$1" || client_failure post-sync-private-http
CLIENT_VERIFY
then
  ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s <<'GATEWAY_FAILURE_DIAGNOSTICS'
set -euo pipefail
if systemctl is-active --quiet xconnect-gateway-xray.service; then echo 'gateway_xray_process=active'; else echo 'gateway_xray_process=inactive'; fi
if ss -ltn | grep -Eq ':443[[:space:]]'; then echo 'gateway_xray_listener=active'; else echo 'gateway_xray_listener=inactive'; fi
if ip link show xconzero0 >/dev/null 2>&1; then echo 'gateway_wireguard_interface=active'; else echo 'gateway_wireguard_interface=inactive'; fi
handshake_age=$(wg show xconzero0 latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2 > 0 {age=now-$2} END {print age=="" ? "none" : age}')
echo "gateway_wireguard_handshake_age_seconds=$handshake_age"
GATEWAY_FAILURE_DIAGNOSTICS
  exit 1
fi

ssh "${CLIENT_SSH[@]}" "$client_user@$client" sudo bash -s -- \
  one /var/lib/xconnect-one "$client_transport_endpoint" "$transport_server_name" "$xhttp_path" "$xhttp_mode" "$xhttp_host" \
  < "$ROOT/.github/scripts/xconnect-lab/verify-xhttp-runtime.sh"

ssh "${GATEWAY_SSH[@]}" "$gateway_user@$gateway" sudo bash -s -- "$client_public_key" "$gateway_id" "$network_id" "$formal_zero" "$client_wireguard_ip" <<'RELAY_VERIFY'
set -euo pipefail
wg show xconzero0 latest-handshakes | awk -v peer="$1" -v now="$(date +%s)" '$1 == peer && $2 > 0 && now-$2 >= 0 && now-$2 < 180 {ok=1} END {exit !ok}'
jq -e --arg gateway "$2" --arg network "$3" --arg controller "$4" \
  '.gateway_id == $gateway and .network_id == $network and .controller == $controller and .applied_generation > 0 and (.applied_config_id | length) > 0' \
  /var/lib/xconnect-gateway/state.json >/dev/null
ip route get "$5" | grep -Fq 'dev xconzero0'
RELAY_VERIFY

echo 'PASS: formal UAT Accounts enrollment, released Gateway and Linux One, signed sync/ACK, external Xray/WireGuard, private ping/HTTP and exact-peer handshake on both sides.'
echo 'Not covered by Linux PASS: authenticated Portal data, macOS/Windows private HTTP, or policy enforcement/revocation.'
if [[ "$gateway_provider" != external && ( "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" != 0 || "${NODE_OBSERVATION_WINDOW_MINUTES:-0}" != 0 ) ]]; then
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
  install -m 644 "$LAB_DIR/tls/gateway-ca.crt" "$public_dir/ca.crt"
  jq -n \
    --arg run "$run_id" --arg expires "$expires" --arg network "$network_id" --arg gateway_id "$gateway_id" \
    --arg gateway_key "$gateway_public_key" --arg gateway_host "$gateway_transport" \
    --arg accounts "$formal_zero" --arg portal "$formal_portal" \
    --arg gateway_instance "$gateway_instance" --arg gateway_public "$gateway" --arg gateway_private "$gateway_private" \
    --arg client_instance "$client_instance" --arg client_public "$client" --arg client_private "$client_private" --arg target_ip "$gateway_wireguard_ip" \
    '{run:$run,expires_at:$expires,network_id:$network,gateway_id:$gateway_id,gateway_public_key:$gateway_key,
      gateway_endpoint:{host:$gateway_host,port:443,server_name:"xconnect-lab.invalid"},
      accounts_url:$accounts,portal_url:$portal,
      instances:{gateway:{instance_id:$gateway_instance,public_ip:$gateway_public,private_ip:$gateway_private},
                 linux_one:{instance_id:$client_instance,public_ip:$client_public,private_ip:$client_private}},
      expected_device_ids:{darwin:("one-darwin-" + $run),windows:("one-windows-" + $run)},
      verification:{target:("http://" + $target_ip + ":8080/"),expected_marker:$run}}' > "$handoff"
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
  observability) test -f "$LAB_DIR/one.done"; deploy_observability ;;
  verify) test -f "$LAB_DIR/observability.done"; verify_overlay ;;
  all) prepare_runtime; bootstrap_accounts; enroll_gateway; enroll_one; deploy_observability; verify_overlay ;;
  *) echo 'Unknown deployment stage' >&2; exit 1 ;;
esac
touch "$LAB_DIR/$stage.done"
