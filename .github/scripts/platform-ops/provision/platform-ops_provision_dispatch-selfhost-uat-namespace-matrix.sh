#!/usr/bin/env bash
set -euo pipefail

# Aggregate UAT deployment is an orchestration operation only. Each child
# selfhost run owns exactly one Akamai Terraform namespace and performs its
# own Terraform apply followed by the matching bootstrap/application jobs.
# The parent never renders Terraform and never gets a shared state key.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"
: "${CHILD_WORKFLOW:?CHILD_WORKFLOW is required}"
: "${ACCOUNT:?ACCOUNT is required}"
: "${DEPLOY_TAG:?DEPLOY_TAG is required}"
: "${SOURCE_REF:?SOURCE_REF is required}"
: "${SOURCE_HOST:?SOURCE_HOST is required}"
: "${SOURCE_DOMAIN_BASE:?SOURCE_DOMAIN_BASE is required}"
: "${TARGET_DOMAIN_BASE:?TARGET_DOMAIN_BASE is required}"
: "${OBSERVABILITY_ENDPOINT:?OBSERVABILITY_ENDPOINT is required}"
: "${INSTANCE_PLAN:?INSTANCE_PLAN is required}"
: "${AGENT_PROXY_PLAN:?AGENT_PROXY_PLAN is required}"
: "${OPEN_PLATFORM_SERVICE:?OPEN_PLATFORM_SERVICE is required}"
: "${SKIP_STRIPE_CATALOG:?SKIP_STRIPE_CATALOG is required}"
: "${VAULT_ADDR:?VAULT_ADDR is required}"

RUNNER_TYPE="${RUNNER_TYPE:-ubuntu-latest}"
OFFLINE_MODE="${OFFLINE_MODE:-off}"
XRAY_EXPORTER_IMAGE="${XRAY_EXPORTER_IMAGE:-}"
INCLUDE_EXTERNAL_AGENT_PROXY="${INCLUDE_EXTERNAL_AGENT_PROXY:-true}"
DNS_MODE="${DNS_MODE:-none}"
AGENT_CONTROLLER_URL="${AGENT_CONTROLLER_URL:-}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-15}"

[[ "${TARGET_DOMAIN_BASE}" == "onwalk.net" ]] || {
  echo "::error::UAT Akamai namespace deployment requires target_domain_base=onwalk.net" >&2
  exit 1
}
[[ "${DEPLOY_TAG}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::Refusing a non-immutable UAT deploy tag: ${DEPLOY_TAG}" >&2
  exit 1
}
[[ "${OBSERVABILITY_ENDPOINT}" =~ ^https?://[^[:space:]]+$ ]] || {
  echo "::error::OBSERVABILITY_ENDPOINT must be an HTTP(S) URL" >&2
  exit 1
}
[[ "${INCLUDE_EXTERNAL_AGENT_PROXY}" == true || "${INCLUDE_EXTERNAL_AGENT_PROXY}" == false ]] || {
  echo "::error::INCLUDE_EXTERNAL_AGENT_PROXY must be true or false" >&2
  exit 1
}
[[ "${SKIP_STRIPE_CATALOG}" == true || "${SKIP_STRIPE_CATALOG}" == false ]] || {
  echo "::error::SKIP_STRIPE_CATALOG must be true or false" >&2
  exit 1
}

export GH_TOKEN

dispatch_and_wait() {
  local namespace="${1:?namespace is required}"
  local include_external="${2:?external-node flag is required}"
  local child_dns_mode="${3:?dns mode is required}"
  local dispatch_started run_id="" payload

  dispatch_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  payload="$(jq -n \
    --arg runner_type "${RUNNER_TYPE}" \
    --arg deploy_tag "${DEPLOY_TAG}" \
    --arg source_ref "${SOURCE_REF}" \
    --arg offline_mode "${OFFLINE_MODE}" \
    --arg source_host "${SOURCE_HOST}" \
    --arg source_domain_base "${SOURCE_DOMAIN_BASE}" \
    --arg target_domain_base "${TARGET_DOMAIN_BASE}" \
    --arg observability_endpoint "${OBSERVABILITY_ENDPOINT}" \
    --arg xray_exporter_image "${XRAY_EXPORTER_IMAGE}" \
    --arg operation deploy \
    --arg target_domains "${namespace}" \
    --arg open_platform_service "${OPEN_PLATFORM_SERVICE}" \
    --arg cloud_provider akamai-cloud \
    --arg cloud_account "${ACCOUNT}" \
    --arg akamai_account "${ACCOUNT}" \
    --arg include_external_agent_proxy "${include_external}" \
    --arg instance_plan "${INSTANCE_PLAN}" \
    --arg agent_proxy_plan "${AGENT_PROXY_PLAN}" \
    --arg dns_mode "${child_dns_mode}" \
    --arg vault_env_path uat \
    --arg skip_stripe_catalog "${SKIP_STRIPE_CATALOG}" \
    --arg agent_controller_url "${AGENT_CONTROLLER_URL}" \
    --arg vault_addr "${VAULT_ADDR}" \
    '{ref:"main", inputs:{
      runner_type:$runner_type,
      deploy_tag:$deploy_tag,
      source_ref:$source_ref,
      offline_mode:$offline_mode,
      source_host:$source_host,
      source_domain_base:$source_domain_base,
      target_domain_base:$target_domain_base,
      observability_endpoint:$observability_endpoint,
      xray_exporter_image:$xray_exporter_image,
      operation:$operation,
      target_domains:$target_domains,
      open_platform_service:$open_platform_service,
      cloud_provider:$cloud_provider,
      cloud_account:$cloud_account,
      akamai_account:$akamai_account,
      include_external_agent_proxy:$include_external_agent_proxy,
      instance_plan:$instance_plan,
      agent_proxy_plan:$agent_proxy_plan,
      dns_mode:$dns_mode,
      vault_env_path:$vault_env_path,
      skip_stripe_catalog:$skip_stripe_catalog,
      agent_controller_url:$agent_controller_url,
      vault_addr:$vault_addr
    }}')"

  gh api --method POST "repos/${GH_REPO}/actions/workflows/${CHILD_WORKFLOW}/dispatches" \
    --input - <<<"${payload}" >/dev/null

  for _ in $(seq 1 45); do
    run_id="$(gh run list --repo "${GH_REPO}" --workflow "${CHILD_WORKFLOW}" \
      --event workflow_dispatch --limit 50 \
      --json databaseId,createdAt,headBranch \
      --jq "[.[] | select(.headBranch == \"main\" and .createdAt >= \"${dispatch_started}\")] | sort_by(.createdAt) | last | .databaseId // empty")"
    if [[ -n "${run_id}" ]]; then
      break
    fi
    sleep 2
  done
  [[ -n "${run_id}" ]] || {
    echo "::error::Could not locate ${CHILD_WORKFLOW} run for ${namespace}" >&2
    exit 1
  }

  echo "${namespace}: dispatched selfhost deploy run ${run_id}"
  gh run watch "${run_id}" --repo "${GH_REPO}" --interval "${WAIT_INTERVAL_SECONDS}" --exit-status --compact
  echo "${namespace}: selfhost deploy run ${run_id} succeeded"
}

# Keep this order aligned with the UAT migration and state-isolation contract.
# The final Agent Proxy child owns the TW/PH external-node pass so those nodes
# are configured once after all Akamai Terraform namespaces are healthy.
namespaces=(
  "open-platform|false|none"
  "web-saas|false|${DNS_MODE}"
  "ai-workspace|false|none"
  "agent-proxy-jp|false|none"
  "agent-proxy-us|false|none"
  "agent-proxy-sg|${INCLUDE_EXTERNAL_AGENT_PROXY}|none"
)

for namespace_spec in "${namespaces[@]}"; do
  IFS='|' read -r namespace include_external child_dns_mode <<<"${namespace_spec}"
  echo "::group::UAT Akamai namespace ${namespace} (deploy)"
  dispatch_and_wait "${namespace}" "${include_external}" "${child_dns_mode}"
  echo "::endgroup::"
done

echo "UAT all-service deployment completed across six isolated Akamai namespaces."
