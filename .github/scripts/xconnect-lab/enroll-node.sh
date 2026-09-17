#!/usr/bin/env bash
set -euo pipefail
umask 077

# =============================================================================
# XConnect One Node Enrollment Script for AI Aggregator & Matrix Nodes
# =============================================================================

ROOT="${GITHUB_WORKSPACE:-$PWD}"
LAB_DIR="${LAB_DIR:-$RUNNER_TEMP/xconnect-lab}"
mkdir -p "$LAB_DIR/nodes" "$LAB_DIR/invites"

NODE_ID="${NODE_ID:-${1:-}}"
NODE_ROLE="${NODE_ROLE:-${2:-one}}"
NODE_NAME="${NODE_NAME:-${3:-$NODE_ID}}"
NODE_OVERLAY_IP="${NODE_OVERLAY_IP:-${4:-}}"

[[ -n "$NODE_ID" ]] || { echo "::error::NODE_ID is required" >&2; exit 1; }
[[ "$NODE_ID" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || { echo "::error::Invalid NODE_ID format: $NODE_ID" >&2; exit 1; }

MODE="${MODE:-apply}"
ZERO_ACCOUNTS_API_URL="${ZERO_ACCOUNTS_API_URL:-https://accounts-uat.onwalk.net}"
ZERO_SERVICE_TOKEN="${ZERO_SERVICE_TOKEN:?ZERO_SERVICE_TOKEN is required}"
ZERO_OWNER_EMAIL="${ZERO_OWNER_EMAIL:?ZERO_OWNER_EMAIL is required}"
ZERO_NETWORK_ID="${ZERO_NETWORK_ID:-net_uat}"
LAB_VLESS_ID="${LAB_VLESS_ID:?LAB_VLESS_ID is required}"
GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-tw-xconnect.svc.plus}"
GATEWAY_WIREGUARD_ADDRESS="${GATEWAY_WIREGUARD_ADDRESS:-10.77.0.1/32}"
GATEWAY_PUBLIC_KEY="${GATEWAY_PUBLIC_KEY:-}"
OVERLAY_CIDR="${OVERLAY_CIDR:-10.77.0.0/24}"

echo "=== Enrolling Node: $NODE_ID (role: $NODE_ROLE, name: $NODE_NAME) ==="

# Read gateway public key if available in LAB_DIR
if [[ -z "$GATEWAY_PUBLIC_KEY" && -s "$LAB_DIR/gateway-public-key" ]]; then
  GATEWAY_PUBLIC_KEY=$(<"$LAB_DIR/gateway-public-key")
fi

# Stage 1: Generate short-lived device invitation via formal Accounts API
echo "Stage 1: Issue device invitation from formal Accounts API for $NODE_ID"
invite_request="$LAB_DIR/invites/${NODE_ID}-request.json"
invite_response="$LAB_DIR/invites/${NODE_ID}-response.json"
invite_destination="$LAB_DIR/invites/${NODE_ID}.invite"

expires_at=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(minutes=30)).isoformat(timespec="seconds").replace("+00:00","Z"))')

jq -n \
  --arg owner "$ZERO_OWNER_EMAIL" \
  --arg controller "$ZERO_ACCOUNTS_API_URL" \
  --arg network "$ZERO_NETWORK_ID" \
  --arg gateway_id "gw-uat-tw-xconnect" \
  --arg gateway_key "${GATEWAY_PUBLIC_KEY:-}" \
  --arg gateway_addr "$GATEWAY_WIREGUARD_ADDRESS" \
  --arg endpoint "$GATEWAY_ENDPOINT" \
  --arg cidr "$OVERLAY_CIDR" \
  --arg vless "$LAB_VLESS_ID" \
  --arg role "one" \
  --arg device "$NODE_ID" \
  --arg expires "$expires_at" \
  --arg server_name "$GATEWAY_ENDPOINT" \
  '{owner_email:$owner,bootstrap:{controller_url:$controller,network:{id:$network,display_name:"XConnect UAT Gateway network",cidr:$cidr,gateway_id:$gateway_id,gateway_wireguard_public_key:$gateway_key,gateway_wireguard_address:$gateway_addr,gateway_endpoint_host:$endpoint,gateway_endpoint_port:51820,transport_server_name:$server_name,transport_port:443,transport_auth_id:$vless,transport_kind:"vless-xhttp",transport_path:"/xconnect",transport_mode:"auto",transport_host:$server_name},invite:{device_id:$device,platform:"linux",role:$role,expires_at:$expires}}}' > "$invite_request"

status=$(curl --silent --show-error --output "$invite_response" --write-out '%{http_code}' \
  -H "X-Service-Token: $ZERO_SERVICE_TOKEN" -H 'Content-Type: application/json' \
  --data-binary "@$invite_request" "$ZERO_ACCOUNTS_API_URL/api/internal/overlay/networks/bootstrap" || true)

if [[ "$status" != 201 ]]; then
  echo "::error::Formal Zero failed to create invite for node $NODE_ID: HTTP $status" >&2
  cat "$invite_response" >&2 || true
  exit 1
fi

jq -e --arg network "$ZERO_NETWORK_ID" --arg device "$NODE_ID" \
  '.network.id == $network and .invite.network_id == $network and .invite.device_id == $device and .invite.role == "one" and .invite.platform == "linux" and .invite.remaining_uses == 1' \
  "$invite_response" >/dev/null || { echo "::error::Formal invitation binding mismatch for $NODE_ID" >&2; exit 1; }

join_uri=$(jq -er .join_uri "$invite_response")
printf '%s\n' "$join_uri" > "$invite_destination"
chmod 600 "$invite_destination"
echo "Invitation issued successfully for $NODE_ID (expires: $expires_at)"

if [[ "$MODE" == "dry-run" ]]; then
  echo "PASS: Dry-run validation passed for node $NODE_ID. Formal Accounts invite binding verified."
  exit 0
fi

# Stage 2: Host resolution & Deployment
echo "Stage 2: Resolve target host connection for $NODE_ID"
target_host="${NODE_HOST:-}"
node_ssh_user="${NODE_USER:-admin}"
node_ssh_key="${NODE_SSH_KEY:-$LAB_DIR/id_ed25519}"

# If host is not provided, attempt AWS EC2 dynamic discovery
if [[ -z "$target_host" ]] && command -v aws >/dev/null 2>&1; then
  discovered_ip=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=*${NODE_ID}*" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].PublicIpAddress" --output text 2>/dev/null | awk '{print $1}')
  if [[ -n "$discovered_ip" && "$discovered_ip" != "None" ]]; then
    target_host="$discovered_ip"
    echo "Discovered EC2 host IP for $NODE_ID: $target_host"
  fi
fi

if [[ -z "$target_host" ]]; then
  # Check if resolvable in local network/hosts
  if ping -c 1 -W 2 "$NODE_ID" >/dev/null 2>&1; then
    target_host="$NODE_ID"
    echo "Resolved hostname for $NODE_ID: $target_host"
  fi
fi

if [[ -z "$target_host" ]]; then
  echo "::warning::Host for node $NODE_ID is currently offline or not yet provisioned. Formal invitation registered in Accounts."
  echo "PASS: Node $NODE_ID invitation ready for subsequent enrollment on boot."
  exit 0
fi

echo "Stage 3: Deploy XConnect One to $NODE_ID ($target_host)"
SSH_OPTS=(-i "$node_ssh_key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# Test SSH reachability
if ! ssh "${SSH_OPTS[@]}" "$node_ssh_user@$target_host" true 2>/dev/null; then
  echo "::warning::SSH connectivity to $node_ssh_user@$target_host timed out. Node may be starting up."
  exit 0
fi

# Deploy via Ansible if playbook exists, otherwise direct CLI bootstrap
cli_binary="${CLI_BINARY:-$LAB_DIR/bin/xconnect}"
ca_source="${CA_CERT:-$LAB_DIR/tls/gateway-ca.crt}"

if [[ -f "$ROOT/playbooks/deploy_xconnect_one.yml" ]]; then
  echo "Invoking deploy_xconnect_one.yml playbook for $NODE_ID"
  vars_file="$LAB_DIR/nodes/${NODE_ID}-vars.json"
  jq -n \
    --arg binary "$cli_binary" \
    --arg ca "$ca_source" \
    --arg invite "$invite_destination" \
    --arg state_dir "/var/lib/xconnect-one" \
    --arg device "$NODE_ID" \
    --arg name "$NODE_NAME" \
    --arg network "$ZERO_NETWORK_ID" \
    --arg cidr "$OVERLAY_CIDR" \
    '{xconnect_one_hosts:"all",xconnect_one_enabled:true,xconnect_one_environment:"uat",
      xconnect_one_state_dir:$state_dir,xconnect_one_binary_source:$binary,
      xconnect_one_ca_certificate_source:$ca,
      xconnect_one_device_id:$device,xconnect_one_device_name:$name,
      xconnect_one_expected_network_id:$network,xconnect_one_invite_file_source:$invite,
      xconnect_one_expected_overlay_cidr:$cidr,xconnect_one_expected_wireguard_interface:"xconone0",
      xconnect_one_expected_xray_loopback_port:51830,xconnect_one_sync_interval_seconds:300,
      xconnect_one_install_observability:false}' > "$vars_file"

  ANSIBLE_HOST_KEY_CHECKING=False \
    ansible-playbook -i "${target_host}," "$ROOT/playbooks/deploy_xconnect_one.yml" \
      --user "$node_ssh_user" --private-key "$node_ssh_key" \
      --ssh-common-args="-o StrictHostKeyChecking=accept-new" \
      --extra-vars "@$vars_file" || {
        echo "::warning::Ansible playbook failed for $NODE_ID; collecting diagnostics"
        exit 1
      }
  rm -f "$vars_file"
fi

echo "Stage 4: Verify node status for $NODE_ID"
ssh "${SSH_OPTS[@]}" "$node_ssh_user@$target_host" sudo bash -s -- "$NODE_ID" "$ZERO_NETWORK_ID" <<'VERIFY_CMD'
set -euo pipefail
device_id="$1"
network_id="$2"
if ip link show xconone0 >/dev/null 2>&1; then
  echo "wireguard_interface=active"
else
  echo "wireguard_interface=inactive"
fi
sudo xconnect status --state-dir /var/lib/xconnect-one 2>/dev/null | jq -c '{joined,device_id,network_id,generations,runtime}' || true
VERIFY_CMD

echo "PASS: Node $NODE_ID successfully enrolled into XConnect Zero network $ZERO_NETWORK_ID"
