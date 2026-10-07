#!/usr/bin/env bash
set -euo pipefail
umask 077
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]] || { control_error; exit 1; }
case "${CONTROL_MODE:-}" in standby|availability|initialization|billing|full-business) ;; *) control_error; exit 1 ;; esac
: "${CONTROL_CONTRACT:?}" "${CONTROL_DESTINATION:?}" "${RUNNER_TEMP:?}" "${GH_TOKEN:?}" "${GITHUB_OUTPUT:?}"
[[ "$CONTROL_CONTRACT" == .github/config/*.yaml && -f "$CONTROL_CONTRACT" ]] || { control_error; exit 1; }
[[ "$CONTROL_DESTINATION" == "$RUNNER_TEMP/"* && "$CONTROL_DESTINATION" != *'/../'* &&
   "$CONTROL_DESTINATION" != */.. && ! -e "$CONTROL_DESTINATION" && ! -L "$CONTROL_DESTINATION" ]] || { control_error; exit 1; }
work="$(mktemp -d "$RUNNER_TEMP/prod-control.XXXXXX")"
trap 'status=$?; rm -rf -- "$work"; if (( status != 0 )); then rm -rf -- "$CONTROL_DESTINATION"; fi' EXIT
trap 'control_error' ERR
contract="$work/contract.json"
yq -o=json '.' "$CONTROL_CONTRACT" > "$contract"
validate_input
validate_contract

api_json() {
  local path="$1" destination="$2"
  # Private API diagnostics and signed redirect URLs never enter logs.
  gh api "repos/ai-workspace-infra/platform-ops-toolkit$path" > "$destination" 2>/dev/null || return 1
  jq -e 'type == "object" or type == "array"' "$destination" >/dev/null
}

fetch_parent() {
  local kind="$1" key run_id artifact_id workflow_id name maximum
  case "$kind" in
    resource) key=resource; name='cmdb.json inventory.ini hosts_manifest.json'; maximum=2097152 ;;
    standby) key=standby; name=prod-native-standby-receipt.json; maximum=65536 ;;
    initialized) key=initialized; name=prod-native-init-receipt.json; maximum=65536 ;;
    billing) key=upgraded; name=prod-native-billing-receipt.json; maximum=65536 ;;
    copy) key=copied; name=prod-full-business-receipt.json; maximum=65536 ;;
    *) return 1 ;;
  esac
  run_id=$(jq -er --arg key "$key" '.[$key].run_id | select(type == "number" and floor == . and . > 0)' "$contract")
  artifact_id=$(jq -er --arg key "$key" '.[$key].artifact_id | select(type == "number" and floor == . and . > 0)' "$contract")
  api_json "/actions/runs/$run_id" "$work/$kind-run.json"
  workflow_id=$(jq -er '.workflow_id | select(type == "number" and floor == . and . > 0)' "$work/$kind-run.json")
  api_json "/actions/workflows/$workflow_id" "$work/$kind-workflow.json"
  api_json "/actions/artifacts/$artifact_id" "$work/$kind-artifact.json"
  validate_parent "$kind" "$work/$kind-run.json" "$work/$kind-workflow.json" "$work/$kind-artifact.json"
  timeout 120 gh api "repos/ai-workspace-infra/platform-ops-toolkit/actions/artifacts/$artifact_id/zip" 2>/dev/null |
    head -c "$((maximum + 1))" > "$work/$kind.zip"
  safe_archive "$work/$kind.zip" "$key" "$name" "$maximum"
  if [[ "$kind" == resource ]]; then
    stage_resource
  else
    [[ $(zipinfo -1 "$work/$kind.zip" | wc -l) -eq 1 ]]
    stream_member "$work/$kind.zip" "$name" "$work/$kind-receipt.json" "$maximum"
    [[ $(digest "$work/$kind-receipt.json") == "$(jq -er --arg key "$key" '.[$key].receipt_sha256' "$contract")" ]]
    validate_receipt "$kind" "$work/$kind-receipt.json"
  fi
}

stage_resource() {
  local member
  for member in cmdb.json inventory.ini; do
    zipinfo -1 "$work/resource.zip" | grep -Fxq "$member"
    stream_member "$work/resource.zip" "$member" "$work/$member" 2097152
  done
  [[ $(digest "$work/cmdb.json") == "$(jq -er '.resource.cmdb_sha256' "$contract")" ]]
  [[ $(digest "$work/inventory.ini") == "$(jq -er '.resource.inventory_sha256' "$contract")" ]]
  check_json '. as $c | .["web-saas-prod"] as $h |
    $c.environment == "prod" and $c.project_id == "open-platform-prod" and
    $c.deploy_account == "github-actions-prod@open-platform-prod.iam.gserviceaccount.com" and
    $h.provider == "gcp-cloud" and $h.zone == "asia-east1-a" and $h.provisioning_model == "STANDARD" and
    ($h.groups | index("web_saas")) != null and
    $h.data_disk.id == "projects/open-platform-prod/zones/asia-east1-a/disks/web-saas-prod-data" and
    $h.data_disk.mount_path == "/data"' "$work/cmdb.json"
  if zipinfo -1 "$work/resource.zip" | grep -Fxq hosts_manifest.json; then
    stream_member "$work/resource.zip" hosts_manifest.json "$work/hosts_manifest.json" 2097152
  fi
  mkdir -m 700 "$CONTROL_DESTINATION"
  for member in cmdb.json inventory.ini hosts_manifest.json; do
    [[ ! -f "$work/$member" ]] || cp "$work/$member" "$CONTROL_DESTINATION/$member"
  done
}

operation=$(jq -er '.inputs.operation' "$GITHUB_EVENT_PATH")
if [[ "$CONTROL_MODE" != standby && "$CONTROL_MODE" != availability ]]; then
  api_json "/actions/runs/$GITHUB_RUN_ID" "$work/current-run.json"
  printf '{}\n' > "$work/environment.json"
  printf '[]\n' > "$work/approvals.json"
  if jq -e '.independent_data_review_required == true' "$contract" >/dev/null; then
    api_json /environments/prod "$work/environment.json"
    api_json "/actions/runs/$GITHUB_RUN_ID/approvals" "$work/approvals.json"
  fi
  validate_review "$work/current-run.json" "$work/environment.json" "$work/approvals.json"
  if [[ "$operation" != native-core-users && "$operation" != native-core-users-compare ]]; then
    fetch_parent standby
    if [[ "$CONTROL_MODE" == billing || "$CONTROL_MODE" == full-business ]]; then fetch_parent initialized; fi
    if [[ "$CONTROL_MODE" == full-business ]]; then
      fetch_parent billing
      if [[ "$operation" == native-business-compare ]]; then fetch_parent copy; fi
    fi
  fi
fi
fetch_parent resource

# Publish only after every required gate succeeds. Spec files remain private,
# runtime JSON for the existing immutable owner actions; YAML stays authoritative.
case "$CONTROL_MODE" in
  initialization) jq '.initialization' "$contract" > "$RUNNER_TEMP/native-init-spec.json" ;;
  billing) jq '{initialization, billing}' "$contract" > "$RUNNER_TEMP/native-billing-spec.json" ;;
  full-business) jq '{initialization, transfer, source}' "$contract" > "$RUNNER_TEMP/full-business-spec.json" ;;
esac
{
  jq -er '"gitops_commit=" + .gitops_commit, "cmdb_sha256=" + .resource.cmdb_sha256' "$contract"
  case "$CONTROL_MODE" in
    initialization|billing)
      case "$operation" in *-plan) echo dry_run=true ;; *) echo dry_run=false ;; esac
      echo data_gate_verified=true
      if [[ "$CONTROL_MODE" == billing ]]; then jq -er '"billing_commit=" + .billing.commit' "$contract"; fi
      ;;
    full-business)
      case "$operation" in
        native-business-plan) echo mode=preview ;;
        native-business-copy) echo mode=copy ;;
        native-business-compare) echo mode=compare ;;
        native-core-users) echo mode=core_users ;;
        native-core-users-compare) echo mode=core_users_compare ;;
      esac
      echo data_gate_verified=true
      ;;
  esac
} >> "$GITHUB_OUTPUT"
echo 'Immutable PROD control evidence verified.'
