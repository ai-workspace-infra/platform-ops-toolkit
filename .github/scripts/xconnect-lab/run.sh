#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="${GITHUB_WORKSPACE:-$PWD}"
LAB_DIR="${LAB_DIR:?LAB_DIR is required}"
TF="$ROOT/iac_modules/vpn-overlay/xconnect-lab"
DECL="$ROOT/gitops/vpn-overlay/uat/xconnect-lab.json"
die() { echo "::error::$*" >&2; exit 1; }
tf() {
  local command="$1" code
  shift
  local options=(-no-color)
  case "$command" in
    plan|apply|destroy|validate) options+=(-json) ;;
    init) ;;
    *) die 'Unsupported Terraform stage' ;;
  esac
  # Cleanup must not overwrite the failed apply evidence. Raw logs stay private
  # to this runner; only a fixed-vocabulary diagnostic reaches Actions output.
  local log="$LAB_DIR/terraform-${command}.log"
  if terraform -chdir="$TF" "$command" "${options[@]}" "$@" >"$log" 2>&1; then
    return 0
  else
    code=$?
  fi
  python3 "$ROOT/.github/scripts/xconnect-lab/terraform-diagnostics.py" "$command" "$log" "$code" \
    || echo '::error::Terraform failed; safe diagnostic extraction unavailable.' >&2
  exit "$code"
}
tf_read() {
  local command="$1" destination="$2" code
  shift 2
  case "$command" in output|show|state) ;; *) die 'Unsupported Terraform read stage' ;; esac
  # stdout is authoritative private state/output; stderr needs the same safe
  # treatment as apply. A failed state read must never authorize blind destroy.
  local log="$LAB_DIR/terraform-${command}.log"
  if terraform -chdir="$TF" "$command" "$@" >"$destination" 2>"$log"; then
    return 0
  else
    code=$?
  fi
  python3 "$ROOT/.github/scripts/xconnect-lab/terraform-diagnostics.py" "$command" "$log" "$code" \
    || echo '::error::Terraform read failed; safe diagnostic extraction unavailable.' >&2
  echo '::error::Lab state/output inspection failed; resource cleanup is unverified and may require exact-run recovery.' >&2
  exit "$code"
}
case "${1:?command}" in
  validate)
    for name in IAC_REF GITOPS_REF; do
      [[ "${!name:-}" =~ ^[0-9a-f]{40}$ ]] || die "$name requires a full immutable commit SHA"
    done
    [[ "${CLI_RELEASE_TAG:-}" =~ ^v[0-9A-Za-z._-]+$ ]] || die 'CLI_RELEASE_TAG requires a version tag'
    [[ "${GATEWAY_RELEASE_TAG:-}" =~ ^v[0-9A-Za-z._-]+$ ]] || die 'GATEWAY_RELEASE_TAG requires a version tag'
    [[ "${XRAY_RELEASE_TAG:-}" =~ ^v[0-9A-Za-z._-]+$ ]] || die 'XRAY_RELEASE_TAG requires a version tag'
    [[ "${ALLOW_XCONNECT_RELEASE_OVERRIDES:-false}" =~ ^(true|false)$ ]] || die 'ALLOW_XCONNECT_RELEASE_OVERRIDES must be true or false'
    [[ "$MODE" =~ ^(dry-run|apply|cleanup)$ ]] || die 'Invalid mode'
    [[ "${MAC_JOIN_WINDOW_MINUTES:-0}" =~ ^(0|5|10|15)$ ]] || die 'mac_join_window_minutes must be 0, 5, 10, or 15'
    if [[ "${MAC_JOIN_WINDOW_MINUTES:-0}" != 0 && "$MODE" != apply ]]; then
      die 'mac_join_window_minutes is valid only with mode=apply'
    fi
    [[ "${MAC_JOIN_WINDOW_MINUTES:-0}" == 0 ]] || die 'Desktop validation requires scoped external ingress, TLS trust delivery and exact device identity; the former peer-count window is not a valid macOS acceptance test. Use mac_join_window_minutes=0 for Linux validation.'
    [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" =~ ^(0|10|20)$ ]] || die 'desktop_join_window_minutes must be 0, 10, or 20'
    [[ "${NODE_OBSERVATION_INPUT:-auto}" =~ ^(auto|0|10|20|until-expiry)$ ]] || die 'node_observation_window_minutes must be auto, 0, 10, 20, or until-expiry'
    if [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" != 0 && "$MODE" != apply ]]; then
      die 'desktop_join_window_minutes is valid only with mode=apply'
    fi
    if [[ "${NODE_OBSERVATION_INPUT:-auto}" != 0 && "${NODE_OBSERVATION_INPUT:-auto}" != auto && "$MODE" != apply ]]; then
      die 'node_observation_window_minutes is valid only with mode=apply'
    fi
    if [[ "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" != 0 && "${NODE_OBSERVATION_INPUT:-auto}" != 0 && "${NODE_OBSERVATION_INPUT:-auto}" != auto ]]; then
      die 'desktop_join_window_minutes and node_observation_window_minutes are mutually exclusive'
    fi
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-windows \
      "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" "${NODE_OBSERVATION_INPUT:-auto}" \
      || die 'Observation windows are invalid or mutually exclusive'
    if [[ "$MODE" == cleanup ]]; then
      [[ "$CLEANUP_RUN" =~ ^xcl-[0-9]+-[0-9]+$ ]] || die 'cleanup requires an exact previous run identity'
    else
      [[ -z "${CLEANUP_RUN:-}" ]] || die 'cleanup_run is only valid with cleanup'
    fi
    mkdir -p "$LAB_DIR"
    ;;
  topology)
    if [[ "${ALLOW_XCONNECT_RELEASE_OVERRIDES:-false}" == true ]]; then
      jq -e '
        .spec.zero.lab_controller.enabled == false and
        .spec.artifacts.one.repository == "ai-workspace-xstream/XConnect-One" and
        .spec.artifacts.one.asset == "xconnect-linux-arm64" and
        .spec.artifacts.gateway.repository == "ai-workspace-xstream/XConnect-Gateway" and
        .spec.artifacts.gateway.asset == "xconnect-gateway-linux-arm64" and
        .spec.artifacts.xray.repository == "XTLS/Xray-core" and
        .spec.artifacts.xray.asset == "Xray-linux-arm64-v8a.zip"
      ' "$DECL" >/dev/null || die 'Release override is incompatible with the immutable GitOps XConnect artifact contract'
    else
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
    fi
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-desktop "$DECL" "${DESKTOP_JOIN_WINDOW_MINUTES:-0}" || die 'GitOps desktop validation does not authorize the requested join window'
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" validate-transport "$DECL" "${GATEWAY_TRANSPORT_INGRESS_CIDRS:-}" || die 'Gateway public transport ingress is not authorized or is not a canonical IPv4 /32 allowlist'
    jq -e --argjson cleanup "$([[ "$MODE" == cleanup ]] && echo true || echo false)" \
      -f "$ROOT/.github/scripts/xconnect-lab/validate-topology.jq" "$DECL" >/dev/null || die 'Missing or incompatible UAT lab topology'
    resolved_node=$(python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" resolve-node-observation "$DECL" "${NODE_OBSERVATION_INPUT:-auto}" "$MODE" "${DESKTOP_JOIN_WINDOW_MINUTES:-0}") || die 'Node observation window is incompatible with the reviewed topology'
    echo "node_observation_window_minutes=$resolved_node" >> "${GITHUB_OUTPUT:-$LAB_DIR/github-output}"
    echo "NODE_OBSERVATION_WINDOW_MINUTES=$resolved_node" >> "${GITHUB_ENV:-$LAB_DIR/github-env}"
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
    python3 -m unittest discover -s "$ROOT/.github/scripts/xconnect-lab" -p 'test_*.py'
    if [[ "$MODE" != cleanup ]]; then
      test -f "$TF/expiry_timer_test.sh" || die 'Apply requires an IaC revision with independent absolute-expiry protection'
      bash "$TF/contract_test.sh"
    fi
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
    tf_read output "$LAB_DIR/outputs.json" -json
    ;;
  setup|bootstrap|gateway|one|verify|desktop|node-observation)
    [[ "$MODE" == apply && -f "$LAB_DIR/apply-started" && -s "$LAB_DIR/outputs.json" ]] || die 'Real lab provisioning is required before deployment stages'
    if [[ "$1" == desktop ]]; then
      test -f "$LAB_DIR/verify.done" || die 'Linux verification is required before the desktop observation window'
      timeout 25m bash "$ROOT/.github/scripts/xconnect-lab/desktop.sh"
    elif [[ "$1" == node-observation ]]; then
      test -f "$LAB_DIR/verify.done" || die 'Linux verification is required before the node observation window'
      timeout 60m bash "$ROOT/.github/scripts/xconnect-lab/node-observation.sh"
    else
      timeout 25m bash "$ROOT/.github/scripts/xconnect-lab/deploy.sh" "$1"
    fi
    ;;
  cleanup)
    if [[ ! -f "$LAB_DIR/backend-ready" ]]; then echo 'No initialized lab state; no provisioning was allowed.'; exit 0; fi
    if [[ "$MODE" != cleanup && ! -f "$LAB_DIR/apply-started" ]]; then echo 'No apply attempted; no resources to destroy.'; exit 0; fi
    export TF_VAR_run_id="$(<"$LAB_DIR/run-id")"
    # Saved state is authoritative for cleanup, including after partial apply.
    tf_read show "$LAB_DIR/state.json" -json
    python3 "$ROOT/.github/scripts/xconnect-lab/prepare.py" cleanup "$LAB_DIR" "$DECL"
    cp "$LAB_DIR/variables.json" "$TF/terraform.auto.tfvars.json"
    tf destroy -auto-approve -input=false
    tf_read state "$LAB_DIR/remaining" list
    [[ ! -s "$LAB_DIR/remaining" ]] || die "Lab state is not empty: $TF_VAR_run_id"
    bash "$ROOT/.github/scripts/xconnect-lab/lease.sh" delete
    echo "Destroyed lab $TF_VAR_run_id; remote state retained for audit."
    ;;
  *) die 'Unknown command' ;;
esac
