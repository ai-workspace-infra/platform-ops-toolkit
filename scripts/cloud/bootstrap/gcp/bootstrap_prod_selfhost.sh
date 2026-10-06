#!/usr/bin/env bash
# Shell control plane: fixed sources + Vault contract + bounded IaC owner call.
set -euo pipefail
set +x
umask 077

IAC_REF=ee876e29101d251ed19fadb00a3a3f0bcd1987d6
GITOPS_REF=f5083eb7c60d187a648d757d87953ffb59a7e056
OWNER_PATH=terraform-hcl-standard/gcp-cloud/scripts/bootstrap_prod_selfhost.sh
BOOTSTRAP_PATH=kv/CICD/prod/gcp-bootstrap/xworktech
STATE_PATH=kv/CICD/prod/iac_state
STAGE=identity ACTION=plan CHECK=false IAC_DIR= GITOPS_DIR= APPROVED= ACCOUNT= PRIVATE_DIR=
stop() { echo "bootstrap controller stopped: $1" >&2; exit 1; }
cleanup() { if [[ -n "$PRIVATE_DIR" ]]; then rm -rf -- "$PRIVATE_DIR"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
usage() {
  cat <<'EOF'
Usage: bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh
       [--stage identity|external-ip] [--check] [--action plan|apply]
       [--approved-plan-sha256 SHA256] [--bootstrap-account EMAIL]
       [--iac-dir DIR --gitops-dir DIR]
Defaults: identity plan. Clean fixed source checkouts are prepared automatically
under ~/.cache/platform-ops-toolkit/prod-selfhost-bootstrap; no path placeholders.
--check checks fixed sources only; no Vault or GCP access.
--bootstrap-account explicitly delegates one-time local token acquisition to
the fixed IaC owner. Daily deployments continue to use GitHub OIDC.
Apply requires a digest from a reviewed plan for the SAME stage.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;; --check) CHECK=true; shift ;;
    --stage|--action|--approved-plan-sha256|--bootstrap-account|--iac-dir|--gitops-dir)
      [[ $# -ge 2 && -n "$2" ]] || stop 'missing option value'
      case "$1" in
        --stage) STAGE=$2 ;; --action) ACTION=$2 ;; --approved-plan-sha256) APPROVED=$2 ;;
        --bootstrap-account) ACCOUNT=$2 ;; --iac-dir) IAC_DIR=$2 ;; --gitops-dir) GITOPS_DIR=$2 ;;
      esac
      shift 2 ;;
    *) stop 'unsupported option use --help' ;;
  esac
done
[[ "$STAGE" == identity || "$STAGE" == external-ip ]] || stop 'invalid stage'
[[ "$ACTION" == plan || "$ACTION" == apply ]] || stop 'invalid action'
[[ "$ACTION" != apply || "$APPROVED" =~ ^[0-9a-f]{64}$ ]] || stop 'apply requires reviewed plan digest'
[[ -z "$ACCOUNT" || "$ACCOUNT" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || stop 'invalid bootstrap account'
for dependency in git jq; do command -v "$dependency" >/dev/null || stop "missing dependency $dependency"; done
PRIVATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/prod-bootstrap-control.XXXXXXXX") || stop 'cannot create private controller workspace'
verify_checkout() {
  local directory=$1 ref=$2 repository=$3 head remote changes
  [[ "$ref" =~ ^[0-9a-f]{40}$ && -d "$directory" ]] || stop 'fixed source checkout required'
  head=$(git -C "$directory" rev-parse HEAD 2>/dev/null) || stop 'cannot verify fixed source checkout'
  remote=$(git -C "$directory" remote get-url origin 2>/dev/null) || stop 'cannot verify fixed source remote'
  changes=$(git -C "$directory" status --porcelain --untracked-files=all 2>/dev/null) || stop 'cannot inspect source changes'
  [[ "$head" == "$ref" && -z "$changes" ]] || stop 'source must be clean at fixed commit do not reset working files'
  case "$remote" in "https://github.com/$repository"|"https://github.com/$repository.git"|"git@github.com:$repository.git") ;; *) stop 'unexpected source repository' ;; esac
}
prepare_checkout() {
  local provided=$1 ref=$2 repository=$3 destination build
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || stop 'IaC owner must be pinned before execution'
  if [[ -n "$provided" ]]; then
    verify_checkout "$provided" "$ref" "$repository"
    (cd -- "$provided" && pwd)
    return
  fi
  destination="$HOME/.cache/platform-ops-toolkit/prod-selfhost-bootstrap/${repository##*/}-$ref"
  if [[ ! -e "$destination" ]]; then
    mkdir -p -- "$(dirname -- "$destination")"
    build=$(mktemp -d "$(dirname -- "$destination")/.prepare.XXXXXXXX") || stop 'cannot prepare fixed source cache'
    if ! (
      git init -q "$build" &&
      git -C "$build" remote add origin "https://github.com/$repository.git" &&
      if command -v gh >/dev/null; then
        git -C "$build" -c credential.helper= -c 'credential.helper=!gh auth git-credential' fetch -q --depth=1 origin "$ref"
      else git -C "$build" fetch -q --depth=1 origin "$ref"; fi &&
      git -C "$build" checkout -q --detach FETCH_HEAD
    ) >"$PRIVATE_DIR/git.log" 2>&1; then
      rm -rf -- "$build"
      stop 'cannot fetch pinned sources check GitHub access'
    fi
    verify_checkout "$build" "$ref" "$repository"
    # Publish without overwriting an existing cache from another process.
    if [[ -e "$destination" ]]; then rm -rf -- "$build"; else mv -- "$build" "$destination"; fi
  fi
  verify_checkout "$destination" "$ref" "$repository"
  printf '%s\n' "$destination"
}
IAC_DIR=$(prepare_checkout "$IAC_DIR" "$IAC_REF" ai-workspace-infra/iac_modules)
GITOPS_DIR=$(prepare_checkout "$GITOPS_DIR" "$GITOPS_REF" ai-workspace-infra/gitops)
[[ -f "$IAC_DIR/$OWNER_PATH" ]] || stop 'fixed Shell IaC owner missing'
if [[ "$CHECK" == true ]]; then
  jq -n --arg iac "$IAC_REF" --arg gitops "$GITOPS_REF" --arg stage "$STAGE" \
    '{result:"source-contract-verified",owner:"iac_modules",iac_ref:$iac,gitops_ref:$gitops,stage:$stage,
    runtime_identity:"github-actions-prod@open-platform-prod.iam.gserviceaccount.com",
    live_bootstrap_verified:false,database_cutover_approved:false}'
  exit 0
fi
export VAULT_ADDR=https://vault.svc.plus
vault_record() {
  command -v vault >/dev/null || stop 'Vault CLI required for runtime contract'
  vault kv get -format=json "$1" >"$PRIVATE_DIR/vault.json" 2>"$PRIVATE_DIR/vault.log" || stop 'cannot read approved Vault contract'
  jq -e '.data.data|type == "object"' "$PRIVATE_DIR/vault.json" >/dev/null 2>&1 || stop 'invalid Vault contract'
}
if [[ -n "$ACCOUNT" ]]; then
  [[ -z "${GCP_BOOTSTRAP_ACCESS_TOKEN:-}" ]] || stop 'choose explicit account or explicit token'
elif [[ -z "${GCP_BOOTSTRAP_ACCESS_TOKEN:-}" ]]; then
  vault_record "$BOOTSTRAP_PATH"
  jq -e '.data.data.GCP_PROJECT_ID == "open-platform-prod"' "$PRIVATE_DIR/vault.json" >/dev/null || stop 'bootstrap project mismatch'
  GCP_BOOTSTRAP_ACCESS_TOKEN=$(jq -er '.data.data.GCP_ACCESS_TOKEN|select(type == "string" and length > 0)' "$PRIVATE_DIR/vault.json") || stop 'one time bootstrap credential unavailable use approved explicit account or token'
  export GCP_BOOTSTRAP_ACCESS_TOKEN
fi
NEED_STATE=false
for key in TF_STATE_ENDPOINT TF_STATE_BUCKET TF_STATE_ACCESS_KEY TF_STATE_SECRET_KEY TF_STATE_REGION; do
  if [[ -z "${!key:-}" ]]; then NEED_STATE=true; fi
done
if [[ "$NEED_STATE" == true ]]; then
  vault_record "$STATE_PATH"
  for key in TF_STATE_ENDPOINT TF_STATE_BUCKET TF_STATE_ACCESS_KEY TF_STATE_SECRET_KEY TF_STATE_REGION; do
    value=$(jq -er --arg key "$key" '.data.data[$key]|select(type == "string" and length > 0)' "$PRIVATE_DIR/vault.json") || stop 'incomplete Vault state contract'
    export "$key=$value"
  done
fi
COMMAND=(bash "$IAC_DIR/$OWNER_PATH" --gitops-dir "$GITOPS_DIR" --gitops-ref "$GITOPS_REF" --iac-ref "$IAC_REF" --stage "$STAGE" --action "$ACTION")
if [[ "$ACTION" == apply ]]; then COMMAND+=(--approved-plan-sha256 "$APPROVED"); fi
if [[ -n "$ACCOUNT" ]]; then COMMAND+=(--bootstrap-account "$ACCOUNT"); fi
if ! "${COMMAND[@]}" >"$PRIVATE_DIR/receipt.json" 2>"$PRIVATE_DIR/owner.log"; then
  # Only the fixed owner's single static guard reason may be returned.
  reason=$(cat "$PRIVATE_DIR/owner.log")
  if [[ "$reason" =~ ^bootstrap\ stopped:\ [A-Za-z0-9\ /\;,:._\(\)=-]{1,220}$ ]]; then
    stop "fixed IaC owner: $reason"
  fi
  stop 'fixed IaC bootstrap stopped no convergence receipt issued'
fi
if [[ "$ACTION" == apply ]]; then EXPECTED=converged; else EXPECTED=review-required; fi
jq -e --arg iac "$IAC_REF" --arg gitops "$GITOPS_REF" --arg stage "$STAGE" --arg action "$ACTION" --arg result "$EXPECTED" \
  '.schema == 1 and .owner == "iac_modules" and .scope == "prod-selfhost-bootstrap-only" and
  .project == "open-platform-prod" and .iac_ref == $iac and .gitops_ref == $gitops and
  .stage == $stage and .action == $action and .result == $result and
  (.approved_plan_sha256|type == "string" and test("^[0-9a-f]{64}$")) and
  .database_cutover_approved == false' "$PRIVATE_DIR/receipt.json" >/dev/null 2>&1 || stop 'IaC receipt does not match fixed request'
jq . "$PRIVATE_DIR/receipt.json"
