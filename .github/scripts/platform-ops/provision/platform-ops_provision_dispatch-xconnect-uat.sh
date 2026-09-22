#!/usr/bin/env bash
set -euo pipefail

# The selfhost aggregate owns the six Akamai namespace deployments. This
# adapter links the successful aggregate to the independent XConnect Zero
# existing-One workflow without moving XConnect state into a Terraform
# namespace or exposing any Vault credential to the parent workflow.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"
: "${XCONNECT_WORKFLOW:?XCONNECT_WORKFLOW is required}"
: "${XCONNECT_REF:?XCONNECT_REF is required}"
: "${XCONNECT_GATEWAY_REF:?XCONNECT_GATEWAY_REF is required}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-15}"

for value in \
  "${XCONNECT_GATEWAY_REF}"; do
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || {
    echo '::error::XConnect dispatch inputs must not contain newlines' >&2
    exit 1
  }
done

dispatch_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload="$(jq -n \
  --arg ref "${XCONNECT_REF}" \
  --arg gateway_ref "${XCONNECT_GATEWAY_REF}" \
  '{ref:$ref,inputs:{
    deployment_profile:"existing-one",
    mode:"apply",
    gateway_provider:"external",
    external_gateway_server_name:$gateway_ref,
    gateway_vault_key:$gateway_ref,
    matrix_node_filter:"all"
  }}')"

gh api --method POST \
  "repos/${GH_REPO}/actions/workflows/${XCONNECT_WORKFLOW}/dispatches" \
  --input - <<<"${payload}" >/dev/null

run_id=""
for _ in $(seq 1 45); do
  run_id="$(gh run list \
    --repo "${GH_REPO}" \
    --workflow "${XCONNECT_WORKFLOW}" \
    --event workflow_dispatch \
    --limit 50 \
    --json databaseId,createdAt,headBranch \
    --jq "[.[] | select(.headBranch == \"${XCONNECT_REF}\" and .createdAt >= \"${dispatch_started}\")] | sort_by(.createdAt) | last | .databaseId // empty")"
  if [[ -n "${run_id}" ]]; then
    break
  fi
  sleep 2
done

[[ -n "${run_id}" ]] || {
  echo "::error::Could not locate ${XCONNECT_WORKFLOW} run after dispatch" >&2
  exit 1
}

echo "XConnect Zero UAT dispatched as run ${run_id}"
gh run watch "${run_id}" \
  --repo "${GH_REPO}" \
  --interval "${WAIT_INTERVAL_SECONDS}" \
  --exit-status \
  --compact
echo "XConnect Zero UAT run ${run_id} succeeded"
