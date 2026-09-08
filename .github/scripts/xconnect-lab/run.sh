#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="${GITHUB_WORKSPACE:-$PWD}"
LAB_DIR="${LAB_DIR:?LAB_DIR is required}"
TF="$ROOT/iac_modules/vpn-overlay/xconnect-lab"
DECL="$ROOT/gitops/vpn-overlay/uat/xconnect-lab.json"
die() { echo "::error::$*" >&2; exit 1; }
tf() { terraform -chdir="$TF" "$@" >"$LAB_DIR/terraform.log" 2>&1 || die "Terraform $1 failed; protected runner log retained, no secret-bearing output printed."; }
case "${1:?command}" in
  validate)
    for name in IAC_REF GITOPS_REF; do
      [[ "${!name:-}" =~ ^[0-9a-f]{40}$ ]] || die "$name requires a full immutable commit SHA"
    done
    [[ "${CLI_RELEASE_TAG:-}" =~ ^v[0-9A-Za-z._-]+$ ]] || die 'CLI_RELEASE_TAG requires a version tag'
    [[ "${GATEWAY_RELEASE_TAG:-}" =~ ^v[0-9A-Za-z._-]+$ ]] || die 'GATEWAY_RELEASE_TAG requires a version tag'
    [[ "${XRAY_RELEASE_TAG:-}" =~ ^v[0-9A-Za-z._-]+$ ]] || die 'XRAY_RELEASE_TAG requires a version tag'
    [[ "$MODE" =~ ^(dry-run|apply|cleanup)$ ]] || die 'Invalid mode'
    [[ "${MAC_JOIN_WINDOW_MINUTES:-0}" =~ ^(0|5|10|15)$ ]] || die 'mac_join_window_minutes must be 0, 5, 10, or 15'
    if [[ "${MAC_JOIN_WINDOW_MINUTES:-0}" != 0 && "$MODE" != apply ]]; then
      die 'mac_join_window_minutes is valid only with mode=apply'
    fi
    [[ "${MAC_JOIN_WINDOW_MINUTES:-0}" == 0 ]] || die 'Desktop validation requires scoped external ingress, TLS trust delivery and exact device identity; the former peer-count window is not a valid macOS acceptance test. Use mac_join_window_minutes=0 for Linux validation.'
    [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" =~ ^(0|10|20)$ ]] || die 'desktop_join_window_minutes must be 0, 10, or 20'
    [[ "${NODE_OBSERVATION_WINDOW_MINUTES:-0}" =~ ^(0|10|20)$ ]] || die 'node_observation_window_minutes must be 0, 10, or 20'
    if [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" != 0 && "$MODE" != apply ]]; then
      die 'desktop_join_window_minutes is valid only with mode=apply'
    fi
    if [[ "${NODE_OBSERVATION_WINDOW_MINUTES:-0}" != 0 && "$MODE" != apply ]]; then
      die 'node_observation_window_minutes is valid only with mode=apply'
    fi
    if [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" != 0 && "${NODE_OBSERVATION_WINDOW_MINUTES:-0}" != 0 ]]; then
      die 'desktop_join_window_minutes and node_observation_window_minutes are mutually exclusive'
    fi
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-windows \
      "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" "${NODE_OBSERVATION_WINDOW_MINUTES:-0}" \
      || die 'Observation windows are invalid or mutually exclusive'
    if [[ "$MODE" == cleanup ]]; then
      [[ "$CLEANUP_RUN" =~ ^xcl-[0-9]+-[0-9]+$ ]] || die 'cleanup requires an exact previous run identity'
    else
      [[ -z "${CLEANUP_RUN:-}" ]] || die 'cleanup_run is only valid with cleanup'
    fi
    mkdir -p "$LAB_DIR"
    ;;
  topology)
    jq -e --arg cli "$CLI_RELEASE_TAG" --arg gateway "$GATEWAY_RELEASE_TAG" --arg xray "$XRAY_RELEASE_TAG" '
      .spec.zero.lab_controller.enabled == false and
      .spec.artifacts.one.repository == "ai-workspace-xstream/XConnect-One" and
      .spec.artifacts.one.asset == "xconnect-linux-arm64" and
      .spec.artifacts.one.release_tag == $cli and
      .spec.artifacts.gateway.repository == "ai-workspace-xstream/XConnect-Gateway" and
      .spec.artifacts.gateway.asset == "xconnect-gateway-linux-arm64" and
      .spec.artifacts.gateway.release_tag == $gateway and
      .spec.artifacts.xray.repository == "XTLS/Xray-core" and
      .spec.artifacts.xray.asset == "Xray-linux-arm64-v8a.zip" and
      .spec.artifacts.xray.release_tag == $xray
    ' "$DECL" >/dev/null || die 'Release inputs do not match the immutable GitOps XConnect artifact declaration'
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-desktop "$DECL" "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" || die 'GitOps desktop validation does not authorize the requested join window'
    jq -e '.kind == "XConnectLabTopology" and .metadata.environment == "uat" and .spec.iac_module == "vpn-overlay/xconnect-lab" and .spec.environment_reuse == "uat-control-plane-vault-account-and-network" and .spec.gateway_provider == "aws-spot" and .spec.compute_policy == "all-cloud-compute-is-aws-spot-by-default" and .spec.ttl_minutes == 60 and .spec.zero.accounts_api_url == "https://accounts-uat.onwalk.net" and .spec.zero.portal_url == "https://console-cloudflare-uat.onwalk.net/panel/xconnect-zero" and .spec.zero.source_of_truth == "formal-accounts-api-and-portal" and .spec.zero.lab_controller.is_formal_config_source == false and .spec.nodes.gateway.product == "XConnect One Gateway" and .spec.nodes.gateway.role == "relay" and .spec.nodes.gateway.service_role == "relay/service" and .spec.nodes.gateway.baseline == "independent-linux-node-external-wireguard-xray" and .spec.nodes.gateway.architecture == "arm64" and .spec.nodes.gateway.instance_type == "t4g.small" and .spec.nodes.gateway.vcpu == 2 and .spec.nodes.gateway.memory_gib == 2 and .spec.nodes.gateway.purchase_model == "spot" and .spec.nodes.gateway.max_runtime_minutes == 60 and .spec.nodes.one.product == "XConnect One Linux client CLI" and .spec.nodes.one.role == "controlled-client" and .spec.nodes.one.baseline == "independent-linux-node-external-wireguard-xray" and .spec.nodes.one.architecture == "arm64" and .spec.nodes.one.instance_type == "t4g.micro" and .spec.nodes.one.vcpu == 2 and .spec.nodes.one.memory_gib == 1 and .spec.nodes.one.purchase_model == "spot" and .spec.nodes.one.max_runtime_minutes == 60 and .spec.aws.reuse_default_vpc == true and .spec.aws.reuse_default_subnet == true and (.spec.aws.ami_ssm_parameter | contains("/arm64/")) and .spec.vault.address == "https://vault.svc.plus" and .spec.vault.role == "github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab" and .spec.vault.infrastructure_path == "kv/data/CICD/uat" and .spec.vault.runtime_path == "kv/data/uat/xconnect-one" and .spec.vault.github_app_path == "kv/data/CICD/github-app/daily-snapshot" and .spec.overlay.transport == "vless-tls-xudp" and .spec.overlay.gateway_address == "10.77.0.1/32" and .spec.overlay.device_address == "10.77.0.2/32" and .spec.overlay.public_wireguard_ingress == false and (.spec.overlay.private_checks | index("ping")) != null and (.spec.overlay.private_checks | index("http")) != null and (.spec.overlay.private_checks | index("wireguard-handshake")) != null and (.spec.overlay.private_checks | index("config-sync")) != null' "$DECL" >/dev/null || die 'Missing or incompatible UAT lab topology'
    {
      echo "vault_address=$(jq -r .spec.vault.address "$DECL")"
      echo "vault_role=$(jq -r .spec.vault.role "$DECL")"
      echo "aws_role=$(jq -r .spec.aws.role_arn "$DECL")"
      echo "aws_region=$(jq -r .spec.aws.region "$DECL")"
      echo "gateway_provider=$(jq -r .spec.gateway_provider "$DECL")"
      echo "zero_accounts_api_url=$(jq -r .spec.zero.accounts_api_url "$DECL")"
      echo "zero_portal_url=$(jq -r .spec.zero.portal_url "$DECL")"
      echo "lab_controller_mode=$(jq -r .spec.zero.lab_controller.purpose "$DECL")"
    } >> "$GITHUB_OUTPUT"
    ;;
  download)
    mkdir -p "$LAB_DIR/bin"
    release_dir="$LAB_DIR/releases"
    mkdir -p "$release_dir"
    [[ -n "${CLI_RELEASE_TOKEN:-}" ]] || die 'CLI_RELEASE_TOKEN is required to download the private XConnect-One release'
    GH_TOKEN="$CLI_RELEASE_TOKEN" gh release download "$CLI_RELEASE_TAG" \
      --repo ai-workspace-xstream/XConnect-One \
      --pattern 'xconnect-linux-arm64' \
      --pattern 'SHA256SUMS' --dir "$release_dir" --clobber \
      || die "XConnect-One release $CLI_RELEASE_TAG download failed"
    awk '$2 == "dist/xconnect-linux-arm64" {sub("dist/", "", $2); print}' \
      "$release_dir/SHA256SUMS" > "$release_dir/SHA256SUMS.arm64"
    [[ -s "$release_dir/SHA256SUMS.arm64" ]] || die 'XConnect-One release is missing ARM64 checksums'
    (cd "$release_dir" && sha256sum -c SHA256SUMS.arm64) || die 'XConnect-One release checksum verification failed'
    install -m 755 "$release_dir/xconnect-linux-arm64" "$LAB_DIR/bin/xconnect"

    gateway_release_dir="$release_dir/gateway"
    mkdir -p "$gateway_release_dir"
    GH_TOKEN="$CLI_RELEASE_TOKEN" gh release download "$GATEWAY_RELEASE_TAG" \
      --repo ai-workspace-xstream/XConnect-Gateway \
      --pattern 'xconnect-gateway-linux-arm64' \
      --pattern 'SHA256SUMS' --dir "$gateway_release_dir" --clobber \
      || die "XConnect-Gateway release $GATEWAY_RELEASE_TAG download failed"
    awk '$2 == "xconnect-gateway-linux-arm64" || $2 == "dist/xconnect-gateway-linux-arm64" {sub("dist/", "", $2); print}' \
      "$gateway_release_dir/SHA256SUMS" > "$gateway_release_dir/SHA256SUMS.arm64"
    [[ -s "$gateway_release_dir/SHA256SUMS.arm64" ]] || die 'XConnect-Gateway release is missing its ARM64 checksum'
    (cd "$gateway_release_dir" && sha256sum -c SHA256SUMS.arm64) || die 'XConnect-Gateway release checksum verification failed'
    install -m 755 "$gateway_release_dir/xconnect-gateway-linux-arm64" "$LAB_DIR/bin/xconnect-gateway"

    GH_TOKEN="${GITHUB_TOKEN:-}" gh release download "$XRAY_RELEASE_TAG" \
      --repo XTLS/Xray-core \
      --pattern 'Xray-linux-arm64-v8a.zip' \
      --pattern 'Xray-linux-arm64-v8a.zip.dgst' \
      --dir "$release_dir" --clobber \
      || die "Xray release $XRAY_RELEASE_TAG download failed"
    xray_expected=$(awk '$1 == "SHA2-256=" {print $2; exit}' "$release_dir/Xray-linux-arm64-v8a.zip.dgst")
    xray_actual=$(sha256sum "$release_dir/Xray-linux-arm64-v8a.zip" | awk '{print $1}')
    [[ "$xray_expected" =~ ^[0-9a-f]{64}$ && "$xray_expected" == "$xray_actual" ]] || die 'Xray release checksum verification failed'
    unzip -p "$release_dir/Xray-linux-arm64-v8a.zip" xray > "$LAB_DIR/bin/xray" || die 'Xray release archive is missing xray'
    chmod 755 "$LAB_DIR/bin/xray"
    ;;
  preflight)
    terraform -chdir="$TF" fmt -check
    tf init -backend=false -input=false
    tf validate
    echo 'Preflight passed. No resources created; provider credentials/capacity are checked only in apply/cleanup.'
    ;;
  prepare)
    export TF_VAR_run_id="${CLEANUP_RUN:-xcl-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}}"
    printf '%s' "$TF_VAR_run_id" > "$LAB_DIR/run-id"
    [[ "$(aws sts get-caller-identity --query Account --output text)" == "$(jq -r .spec.aws.account_id "$DECL")" ]] || die 'AWS account mismatch'
    # Separate S3 backend credentials from the AWS provider OIDC session.
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" backend "$LAB_DIR" "$DECL"
    tf init -reconfigure -input=false -backend-config="$LAB_DIR/backend.json"
    touch "$LAB_DIR/backend-ready"
    if [[ "$MODE" == apply ]]; then
      for name in LAB_VLESS_ID ZERO_SERVICE_TOKEN ZERO_OWNER_EMAIL; do [[ -n "${!name:-}" ]] || die "Missing Vault runtime field $name"; done
      ssh-keygen -q -t ed25519 -N '' -f "$LAB_DIR/id_ed25519"
      python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" resources "$LAB_DIR" "$DECL"
      cp "$LAB_DIR/variables.json" "$TF/terraform.auto.tfvars.json"
      tf plan -input=false -out="$LAB_DIR/plan"
    fi
    ;;
  apply)
    test -f "$LAB_DIR/backend-ready" || die 'Isolated backend not initialized'
    bash "$ROOT/.github/scripts/xconnect-lab/lease.sh" create
    touch "$LAB_DIR/apply-started"
    tf apply -input=false "$LAB_DIR/plan"
    terraform -chdir="$TF" output -json > "$LAB_DIR/outputs.json"
    ;;
  setup|bootstrap|gateway|one|verify|desktop|node-observation)
    [[ "$MODE" == apply && -f "$LAB_DIR/apply-started" && -s "$LAB_DIR/outputs.json" ]] || die 'Real lab provisioning is required before deployment stages'
    if [[ "$1" == desktop ]]; then
      test -f "$LAB_DIR/verify.done" || die 'Linux verification is required before the desktop observation window'
      timeout 25m bash "$ROOT/.github/scripts/xconnect-lab/desktop.sh"
    elif [[ "$1" == node-observation ]]; then
      test -f "$LAB_DIR/verify.done" || die 'Linux verification is required before the node observation window'
      timeout 25m bash "$ROOT/.github/scripts/xconnect-lab/node-observation.sh"
    else
      timeout 25m bash "$ROOT/.github/scripts/xconnect-lab/deploy.sh" "$1"
    fi
    ;;
  cleanup)
    if [[ ! -f "$LAB_DIR/backend-ready" ]]; then echo 'No initialized lab state; no provisioning was allowed.'; exit 0; fi
    if [[ "$MODE" != cleanup && ! -f "$LAB_DIR/apply-started" ]]; then echo 'No apply attempted; no resources to destroy.'; exit 0; fi
    export TF_VAR_run_id="$(<"$LAB_DIR/run-id")"
    # Saved state is authoritative for cleanup, including after partial apply.
    terraform -chdir="$TF" show -json > "$LAB_DIR/state.json"
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" cleanup "$LAB_DIR" "$DECL"
    cp "$LAB_DIR/variables.json" "$TF/terraform.auto.tfvars.json"
    tf destroy -auto-approve -input=false
    terraform -chdir="$TF" state list > "$LAB_DIR/remaining"
    [[ ! -s "$LAB_DIR/remaining" ]] || die "Lab state is not empty: $TF_VAR_run_id"
    bash "$ROOT/.github/scripts/xconnect-lab/lease.sh" delete
    echo "Destroyed lab $TF_VAR_run_id; remote state retained for audit."
    ;;
  *) die 'Unknown command' ;;
esac
