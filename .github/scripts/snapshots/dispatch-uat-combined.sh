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
xconnect_lab_workflow="${XCONNECT_LAB_WORKFLOW:-xconnect-zero-cloud.yaml}"
gitops_repository="${GITOPS_REPOSITORY:-ai-workspace-infra/gitops}"
iac_repository="${IAC_REPOSITORY:-ai-workspace-infra/iac_modules}"
xconnect_one_release_override="${XCONNECT_ONE_RELEASE_TAG:-}"
xconnect_gateway_release_override="${XCONNECT_GATEWAY_RELEASE_TAG:-}"
agent_controller_url="${AGENT_CONTROLLER_URL:-https://accounts-serverless-uat.onwalk.net}"
agent_proxy_plan="${AGENT_PROXY_PLAN:-1C2G}"
akamai_account="${AKAMAI_ACCOUNT_UAT:-manbuzhe2026}"
aws_account="${AWS_ACCOUNT_UAT:-950604983695}"
gcp_account="${GCP_ACCOUNT_UAT:-xworktech}"
existing_ai_workspace_host="${AI_WORKSPACE_EXISTING_HOST:-10.79.0.7}"
skip_stripe_catalog="${SKIP_STRIPE_CATALOG:-false}"
enable_migration="${ENABLE_MIGRATION:-false}"
apply_accounts_schema_migration="${APPLY_ACCOUNTS_SCHEMA_MIGRATION:-false}"
adopt_accounts_baseline="${ADOPT_ACCOUNTS_BASELINE:-false}"
accounts_source_backend="${ACCOUNTS_SOURCE_BACKEND:-supabase}"
serverless_operation="${SERVERLESS_OPERATION:-}"
wait_timeout_seconds="${UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS:-3600}"
wait_interval_seconds="${UAT_SERVERLESS_WAIT_INTERVAL_SECONDS:-20}"
selfhost_wait_timeout_seconds="${UAT_SELFHOST_WAIT_TIMEOUT_SECONDS:-3600}"

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

[[ "${wait_timeout_seconds}" =~ ^[1-9][0-9]*$ && "${selfhost_wait_timeout_seconds}" =~ ^[1-9][0-9]*$ && "${wait_interval_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::UAT workflow wait timeout and interval must be positive integers." >&2
  exit 2
}

for release_tag in "${xconnect_one_release_override}" "${xconnect_gateway_release_override}"; do
  if [[ -n "${release_tag}" && ! "${release_tag}" =~ ^v[0-9A-Za-z._-]+$ ]]; then
    echo "::error::XConnect release tag overrides must use a v* Release tag." >&2
    exit 2
  fi
done

export GH_TOKEN="${gh_token}"

dispatch_serverless() {
  # UAT deployments do not sync PROD data by default. An explicit
  # enable_migration=true is required for a one-way data merge.
  local op="${serverless_operation}"
  if [[ -z "${op}" ]]; then
    if [[ "${enable_migration}" == "true" ]]; then
      op="deploy+migrate"
    else
      op="deploy"
    fi
  fi

  local -a schema_args=()
  if [[ "${adopt_accounts_baseline}" == "true" ]]; then
    if [[ "${apply_accounts_schema_migration}" != "false" || "${enable_migration}" != "false" || "${op}" != "deploy" ]]; then
      echo "::error::UAT baseline adoption requires operation=deploy without another migration." >&2
      return 2
    fi
    schema_args=(-f adopt_accounts_baseline=true)
  fi
  if [[ "${apply_accounts_schema_migration}" == "true" ]]; then
    if [[ "${enable_migration}" != "false" || "${op}" != "deploy" ]]; then
      echo "::error::UAT schema migration requires operation=deploy and enable_migration=false." >&2
      return 2
    fi
    schema_args=(
      -f apply_accounts_schema_migration=true
      -f "accounts_schema_expected_version=${ACCOUNTS_SCHEMA_EXPECTED_VERSION:?Expected schema version is required}"
      -f "accounts_schema_target_version=${ACCOUNTS_SCHEMA_TARGET_VERSION:?Target schema version is required}"
      -f "accounts_schema_sha256=${ACCOUNTS_SCHEMA_SHA256:?Migration SHA-256 is required}"
    )
  fi

  gh workflow run "${serverless_workflow}" \
    --repo "${target_repo}" \
    --ref main \
    -f "operation=${op}" \
    -f "accounts_source_backend=${accounts_source_backend}" \
    -f target_domains=web-saas \
    -f vault_env_path=uat \
    -f "tag_ref=${snapshot_tag}" \
    -f deploy_cloudflare=true \
    -f deploy_cloud_run=true \
    -f "skip_stripe_catalog=${skip_stripe_catalog}" \
    -f dns_mode=uat-records \
    -f supabase_target_existing_strategy=accounts_merge \
    -f supabase_target_confirm_replace=false \
    "${schema_args[@]}"
}

wait_for_run() {
  local run_url="${1:?run URL is required}"
  local run_label="${2:?run label is required}"
  local timeout_seconds="${3:?timeout is required}"
  local run_id="${run_url##*/}"
  local started_at="${SECONDS}"
  local state status conclusion

  [[ "${run_id}" =~ ^[0-9]+$ ]] || {
    echo "::error::Unable to determine ${run_label} run id from ${run_url}." >&2
    exit 1
  }

  echo "Waiting for ${run_label} UAT deployment ${run_url}..."
  while :; do
    state="$(gh api "repos/${target_repo}/actions/runs/${run_id}" --jq '[.status, (.conclusion // "")] | @tsv')" || {
      echo "::error::Unable to read ${run_label} run ${run_id} status." >&2
      exit 1
    }
    status="${state%%$'\t'*}"
    conclusion="${state#*$'\t'}"

    if [[ "${status}" == "completed" ]]; then
      if [[ "${conclusion}" != "success" ]]; then
        echo "::error::${run_label} run ${run_id} completed with ${conclusion:-no conclusion}." >&2
        exit 1
      fi
      echo "${run_label} UAT deployment ${run_id} completed successfully."
      return 0
    fi

    if [[ "${status}" != "queued" && "${status}" != "in_progress" && "${status}" != "waiting" ]]; then
      echo "::error::${run_label} run ${run_id} returned unexpected status ${status}." >&2
      exit 1
    fi

    if (( SECONDS - started_at >= timeout_seconds )); then
      echo "::error::Timed out waiting for ${run_label} run ${run_id} after ${timeout_seconds}s." >&2
      exit 1
    fi
    sleep "${wait_interval_seconds}"
  done
}

dispatch_selfhost_namespace() {
  local namespace="${1:?namespace is required}"
  local provider="${2:?provider is required}"
  local account="${3:?concrete account is required}"
  local include_external="${4:?external-node flag is required}"
  local dns_mode="${5:?dns mode is required}"
  local instance_plan="${6:?instance plan is required}"
  local existing_target_host="${7:-}"

  # UAT business resources are provider-specific. This dispatcher is retained
  # for the daily snapshot release path, but must never collapse the matrix to
  # Akamai: AI Workspace is existing-selfhost, JP is AWS, US is GCP, and SG is
  # Akamai. Web SaaS is handled by the Serverless child above.
  gh workflow run "${selfhost_workflow}" \
    --repo "${target_repo}" \
    --ref main \
    -f operation=deploy \
    -f vault_env_path=uat \
    -f "target_domains=${namespace}" \
    -f "cloud_provider=${provider}" \
    -f "cloud_account=${account}" \
    -f "akamai_account=${akamai_account}" \
    -f "include_external_agent_proxy=${include_external}" \
    -f "agent_proxy_plan=${agent_proxy_plan}" \
    -f "instance_plan=${instance_plan}" \
    -f "existing_target_host=${existing_target_host}" \
    -f "deploy_tag=${snapshot_tag}" \
    -f source_host=console.svc.plus \
    -f source_domain_base=svc.plus \
    -f target_domain_base=onwalk.net \
    -f "dns_mode=${dns_mode}" \
    -f "skip_stripe_catalog=${skip_stripe_catalog}" \
    -f "agent_controller_url=${agent_controller_url}"
}

serverless_run_url="$(dispatch_serverless | tail -n 1)"
echo "Dispatched UAT serverless deploy for ${snapshot_tag}: ${serverless_run_url}"
wait_for_run "${serverless_run_url}" "serverless" "${wait_timeout_seconds}"

dispatch_xconnect_lab() {
  local topology iac_ref gitops_ref
  local -a workflow_args
  topology="$(mktemp)"
  trap 'rm -f "${topology}"' RETURN

  # GitOps and IAC are reviewed infrastructure repositories, not application
  # build targets, so the daily snapshot does not create a matching tag in
  # either repository. Resolve their protected main branches to immutable
  # commit SHAs before reading the topology or dispatching the lab.
  iac_ref="$(gh api "repos/${iac_repository}/commits/main" --jq .sha)"
  gitops_ref="$(gh api "repos/${gitops_repository}/commits/main" --jq .sha)"
  [[ "${iac_ref}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::IAC main did not resolve to a full commit SHA." >&2; return 1; }
  [[ "${gitops_ref}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::GitOps main did not resolve to a full commit SHA." >&2; return 1; }

  # The lab is enabled by the reviewed GitOps topology introduced in #200.
  # Read it at the resolved commit, never from a floating branch or the
  # application snapshot tag.
  if ! gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/${gitops_repository}/contents/vpn-overlay/uat/xconnect-lab.json?ref=${gitops_ref}" >"${topology}"; then
    echo "::notice::Skipping XConnect UAT Lab for ${snapshot_tag}: reviewed GitOps topology is not present on GitOps main." >&2
    return 0
  fi

  [[ "${iac_ref}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::IAC snapshot did not resolve to a full commit SHA." >&2; return 1; }
  [[ "${gitops_ref}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::GitOps snapshot did not resolve to a full commit SHA." >&2; return 1; }

  cli_release_tag="$(jq -er '.spec.artifacts.one.release_tag' "${topology}")"
  gateway_release_tag="$(jq -er '.spec.artifacts.gateway.release_tag' "${topology}")"
  xray_release_tag="$(jq -er '.spec.artifacts.xray.release_tag' "${topology}")"
  [[ -z "${xconnect_one_release_override}" ]] || cli_release_tag="${xconnect_one_release_override}"
  [[ -z "${xconnect_gateway_release_override}" ]] || gateway_release_tag="${xconnect_gateway_release_override}"
  for release_tag in "${cli_release_tag}" "${gateway_release_tag}" "${xray_release_tag}"; do
    [[ "${release_tag}" =~ ^v[0-9A-Za-z._-]+$ ]] || { echo "::error::Invalid XConnect release tag in GitOps topology." >&2; return 1; }
  done

  workflow_args=(
    workflow run "${xconnect_lab_workflow}"
    --repo "${target_repo}"
    --ref main
    -f mode=apply
    -f "iac_ref=${iac_ref}"
    -f "gitops_ref=${gitops_ref}"
    -f "cli_release_tag=${cli_release_tag}"
    -f "gateway_release_tag=${gateway_release_tag}"
    -f "xray_release_tag=${xray_release_tag}"
  )
  if [[ -n "${xconnect_one_release_override}" || -n "${xconnect_gateway_release_override}" ]]; then
    workflow_args+=(-f allow_release_overrides=true)
  fi
  gh "${workflow_args[@]}"
}

xconnect_lab_run_url="$(dispatch_xconnect_lab)"
if [[ -n "${xconnect_lab_run_url}" ]]; then
  echo "Dispatched XConnect UAT Lab for ${snapshot_tag}: ${xconnect_lab_run_url}"
fi

# Keep the deployment order explicit. This routine UAT release updates only
# business services and their own resources. `open-platform` is intentionally
# absent: Vault and Observability are shared infrastructure and must not be
# re-bootstrapped or restarted as a side effect of an application release.
# Web SaaS is Serverless-only. AI Workspace is an existing host. JP/US/SG use
# their declared providers; none of these rows may silently fall back to
# Akamai.
namespaces=(
  "ai-workspace|gcp-cloud|${gcp_account}|false|none|4C8G|${existing_ai_workspace_host}"
  "agent-proxy-jp|aws-cloud|${aws_account}|false|none|2C2G|"
  "agent-proxy-us|gcp-cloud|${gcp_account}|false|none|2C2G|"
  "agent-proxy-sg|akamai-cloud|${akamai_account}|false|none|2C2G|"
)

for namespace_spec in "${namespaces[@]}"; do
  IFS='|' read -r namespace provider account include_external dns_mode instance_plan existing_target_host <<<"${namespace_spec}"
  selfhost_run_url="$(dispatch_selfhost_namespace "${namespace}" "${provider}" "${account}" "${include_external}" "${dns_mode}" "${instance_plan}" "${existing_target_host}" | tail -n 1)"
  echo "Dispatched UAT selfhost ${namespace} deploy for ${snapshot_tag}: ${selfhost_run_url}"
  echo "Agent Proxy controller: ${agent_controller_url}"
  wait_for_run "${selfhost_run_url}" "selfhost ${namespace}" "${selfhost_wait_timeout_seconds}"
done
