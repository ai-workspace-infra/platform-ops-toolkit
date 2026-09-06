#!/usr/bin/env bash
set -euo pipefail

# The Daily Main Snapshot job is the only trusted producer of this dispatch.
# Keep the two environment copies on the same immutable artifact, and do not
# start the Agent Proxy until the serverless Accounts controller is healthy.

gh_token="${GH_TOKEN:?GH_TOKEN must be set}"
snapshot_tag="${SNAPSHOT_TAG:?SNAPSHOT_TAG must be set}"
target_repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"
serverless_workflow="${SERVERLESS_WORKFLOW:-serverless-orchestrator.yml}"
selfhost_workflow="${SELFHOST_WORKFLOW:-selfhost-orchestrator.yml}"
agent_controller_url="${AGENT_CONTROLLER_URL:-https://accounts-serverless-uat.onwalk.net}"
# UAT validates on an ephemeral AWS Graviton Spot node. T4g.small supplies
# 2 vCPU / 2 GiB; its one-hour lifetime and lack of an EIP are declared in
# the AWS UAT resource configuration.
agent_proxy_plan="${AGENT_PROXY_PLAN:-2C2G}"
skip_stripe_catalog="${SKIP_STRIPE_CATALOG:-false}"
wait_timeout_seconds="${UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS:-3600}"
wait_interval_seconds="${UAT_SERVERLESS_WAIT_INTERVAL_SECONDS:-20}"

[[ "${snapshot_tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::Refusing to dispatch UAT with a non-immutable snapshot tag: ${snapshot_tag}" >&2
  exit 2
}

[[ "${agent_controller_url}" =~ ^https://[^/]+$ ]] || {
  echo "::error::AGENT_CONTROLLER_URL must be an HTTPS origin without a path." >&2
  exit 2
}

[[ "${agent_proxy_plan}" =~ ^(1C1G|1C2G|2C1G|2C2G)$ ]] || {
  echo "::error::AGENT_PROXY_PLAN must be 1C1G, 1C2G, 2C1G, or 2C2G." >&2
  exit 2
}

[[ "${skip_stripe_catalog}" == "true" || "${skip_stripe_catalog}" == "false" ]] || {
  echo "::error::SKIP_STRIPE_CATALOG must be true or false." >&2
  exit 2
}

[[ "${wait_timeout_seconds}" =~ ^[1-9][0-9]*$ && "${wait_interval_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::UAT serverless wait timeout and interval must be positive integers." >&2
  exit 2
}

export GH_TOKEN="${gh_token}"

dispatch_serverless() {
  # Daily releases deploy immutable application artifacts only. User-data
  # migration has a separate explicitly invoked workflow because its source
  # can be private or serverless and must never be assumed SSH-reachable.
  gh workflow run "${serverless_workflow}" \
    --repo "${target_repo}" \
    --ref main \
    -f operation=deploy \
    -f target_domains=web-saas \
    -f vault_env_path=uat \
    -f "tag_ref=${snapshot_tag}" \
    -f deploy_cloudflare=true \
    -f deploy_cloud_run=true \
    -f "skip_stripe_catalog=${skip_stripe_catalog}" \
    -f dns_mode=uat-records \
    -f supabase_target_existing_strategy=accounts_merge \
    -f supabase_target_confirm_replace=false
}

wait_for_serverless() {
  local run_url="${1:?run URL is required}"
  local run_id="${run_url##*/}"

  [[ "${run_id}" =~ ^[0-9]+$ ]] || {
    echo "::error::Unable to determine serverless run id from ${run_url}." >&2
    exit 1
  }

  echo "Waiting for serverless UAT deployment ${run_url} before registering Agent Proxy..."
  gh run watch "${run_id}" --repo "${target_repo}" --interval "${wait_interval_seconds}" --exit-status \
    --compact &
  local watch_pid=$!
  local deadline=$((SECONDS + wait_timeout_seconds))
  while kill -0 "${watch_pid}" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill "${watch_pid}" 2>/dev/null || true
      wait "${watch_pid}" 2>/dev/null || true
      echo "::error::Timed out waiting for serverless run ${run_id} after ${wait_timeout_seconds}s." >&2
      exit 1
    fi
    sleep 1
  done
  wait "${watch_pid}"
}

dispatch_selfhost() {
  gh workflow run "${selfhost_workflow}" \
    --repo "${target_repo}" \
    --ref main \
    -f operation=deploy \
    -f vault_env_path=uat \
    -f target_domains=agent-proxy \
    -f cloud_provider=aws-cloud \
    -f "agent_proxy_plan=${agent_proxy_plan}" \
    -f "deploy_tag=${snapshot_tag}" \
    -f source_host=console.svc.plus \
    -f source_domain_base=svc.plus \
    -f target_domain_base=onwalk.net \
    -f dns_mode=uat-records \
    -f "agent_controller_url=${agent_controller_url}"
}

serverless_run_url="$(dispatch_serverless | tail -n 1)"
echo "Dispatched UAT serverless deploy for ${snapshot_tag}: ${serverless_run_url}"
wait_for_serverless "${serverless_run_url}"

selfhost_run_url="$(dispatch_selfhost | tail -n 1)"
echo "Dispatched UAT selfhost agent-proxy deploy for ${snapshot_tag}: ${selfhost_run_url}"
echo "Agent Proxy controller: ${agent_controller_url}"
