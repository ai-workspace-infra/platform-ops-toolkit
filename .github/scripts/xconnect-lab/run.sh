#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="${GITHUB_WORKSPACE:-$PWD}"
LAB_DIR="${LAB_DIR:?LAB_DIR is required}"
TF="$ROOT/iac_modules/vpn-overlay/xconnect-lab"
DECL="$ROOT/gitops/topology/sit/xconnect-lab.json"
die() { echo "::error::$*" >&2; exit 1; }
tf() { terraform -chdir="$TF" "$@" >"$LAB_DIR/terraform.log" 2>&1 || die "Terraform $1 failed; protected runner log retained, no secret-bearing output printed."; }
case "${1:?command}" in
  validate)
    for name in IAC_REF GITOPS_REF CLI_REF XRAY_REF; do
      [[ "${!name:-}" =~ ^[0-9a-f]{40}$ ]] || die "$name requires a full immutable commit SHA"
    done
    [[ "$MODE" =~ ^(dry-run|apply|cleanup)$ ]] || die 'Invalid mode'
    if [[ "$MODE" == cleanup ]]; then
      [[ "$CLEANUP_RUN" =~ ^xcl-[0-9]+-[0-9]+$ ]] || die 'cleanup requires an exact previous run identity'
    else
      [[ -z "${CLEANUP_RUN:-}" ]] || die 'cleanup_run is only valid with cleanup'
    fi
    mkdir -p "$LAB_DIR"
    ;;
  topology)
    jq -e '.kind == "XConnectLabTopology" and .metadata.environment == "sit" and .spec.ttl_minutes == 90 and .spec.vault.address == "https://vault.svc.plus" and .spec.vault.role == "github-actions-platform-ops-toolkit-sit" and .spec.vault.infrastructure_path == "kv/data/CICD/sit" and .spec.vault.runtime_path == "kv/data/sit/xconnect-one" and .spec.vault.github_app_path == "kv/data/CICD/github-app/daily-snapshot" and .spec.overlay.transport == "vless-tls-xudp" and .spec.overlay.gateway_address == "10.77.0.1/24" and .spec.overlay.device_address == "10.77.0.2/32"' "$DECL" >/dev/null || die 'Missing or incompatible lab topology'
    {
      echo "vault_address=$(jq -r .spec.vault.address "$DECL")"
      echo "vault_role=$(jq -r .spec.vault.role "$DECL")"
      echo "aws_role=$(jq -r .spec.aws.role_arn "$DECL")"
      echo "aws_region=$(jq -r .spec.aws.region "$DECL")"
    } >> "$GITHUB_OUTPUT"
    ;;
  build)
    [[ -f "$ROOT/cli/cmd/xconnect-zero-lab/main.go" ]] || die 'Pinned CLI ref has no real Zero lab server; refusing to substitute a mock'
    mkdir -p "$LAB_DIR/bin"
    (cd "$ROOT/cli"; CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$LAB_DIR/bin/xconnect" ./cmd/xconnect; CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$LAB_DIR/bin/xconnect-zero-lab" ./cmd/xconnect-zero-lab)
    (cd "$ROOT/xray"; CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$LAB_DIR/bin/xray" ./main)
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
      for name in LAB_ADMIN_TOKEN LAB_SIGNING_KEY LAB_VLESS_ID; do [[ -n "${!name:-}" ]] || die "Missing Vault runtime field $name"; done
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
    timeout 25m bash "$ROOT/.github/scripts/xconnect-lab/deploy.sh"
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
