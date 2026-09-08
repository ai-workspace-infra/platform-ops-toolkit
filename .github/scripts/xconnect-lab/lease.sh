#!/usr/bin/env bash
set -euo pipefail
umask 077
mkdir -p "${LAB_DIR:?}"
# Backend-only identity; never replace the AWS provider session in the caller.
state_api() {
  AWS_ACCESS_KEY_ID="$TF_STATE_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$TF_STATE_SECRET_KEY" \
    AWS_SESSION_TOKEN='' AWS_REGION="$TF_STATE_REGION" \
    aws --endpoint-url "$TF_STATE_ENDPOINT" s3api "$@" > "$LAB_DIR/state-api.log" 2>&1
}
prefix=uat/xconnect-lab/_leases
case "${1:?}" in
  create)
    run="$(<"$LAB_DIR/run-id")"
    jq -n --arg run "$run" --arg iac "$IAC_REF" --arg gitops "$GITOPS_REF" \
      --arg cli "$CLI_RELEASE_TAG" --arg gateway "$GATEWAY_RELEASE_TAG" --arg xray "$XRAY_RELEASE_TAG" \
      --arg expires "$(jq -r .expires_at "$LAB_DIR/variables.json")" \
      '{run:$run,expires_at:$expires,inputs:{mode:"cleanup",cleanup_run:$run,iac_ref:$iac,gitops_ref:$gitops,cli_release_tag:$cli,gateway_release_tag:$gateway,xray_release_tag:$xray}}' > "$LAB_DIR/lease.json"
    state_api put-object --bucket "$TF_STATE_BUCKET" --key "$prefix/$run.json" --body "$LAB_DIR/lease.json"
    ;;
  delete)
    run="$(<"$LAB_DIR/run-id")"
    state_api delete-object --bucket "$TF_STATE_BUCKET" --key "$prefix/$run.json"
    ;;
  reap)
    state_api list-objects-v2 --bucket "$TF_STATE_BUCKET" --prefix "$prefix/"
    jq -r '.Contents[]?.Key' "$LAB_DIR/state-api.log" > "$LAB_DIR/keys"
    while IFS= read -r key; do
      [[ "$key" =~ ^uat/xconnect-lab/_leases/xcl-[0-9]+-[0-9]+\.json$ ]] || exit 1
      state_api get-object --bucket "$TF_STATE_BUCKET" --key "$key" "$LAB_DIR/lease.json"
      jq -e --arg key "$key" '.run | test("^xcl-[0-9]+-[0-9]+$")' "$LAB_DIR/lease.json" >/dev/null
      run="$(jq -r .run "$LAB_DIR/lease.json")"
      [[ "$key" == "$prefix/$run.json" ]] || exit 1
      jq -e '.inputs.mode == "cleanup" and .inputs.cleanup_run == .run and ([.inputs.iac_ref,.inputs.gitops_ref] | all(test("^[0-9a-f]{40}$"))) and (.inputs.cli_release_tag | test("^v[0-9A-Za-z._-]+$")) and (.inputs.gateway_release_tag | test("^v[0-9A-Za-z._-]+$")) and (.inputs.xray_release_tag | test("^v[0-9A-Za-z._-]+$"))' "$LAB_DIR/lease.json" >/dev/null
      if jq -e '(.expires_at | fromdateiso8601) <= now' "$LAB_DIR/lease.json" >/dev/null; then
        jq '{ref:"main",inputs:.inputs}' "$LAB_DIR/lease.json" > "$LAB_DIR/dispatch.json"
        gh api --method POST "repos/$GITHUB_REPOSITORY/actions/workflows/xconnect-zero-cloud.yaml/dispatches" --input "$LAB_DIR/dispatch.json" >/dev/null
        echo "Requested expired lab cleanup: $run"
      fi
    done < "$LAB_DIR/keys"
    ;;
  *) exit 1 ;;
esac
