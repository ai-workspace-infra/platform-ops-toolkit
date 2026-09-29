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
aws_account="${AWS_ACCOUNT_UAT:-081434641398}"
gcp_account="${GCP_ACCOUNT_UAT:-xworktech}"
shared_platform_action="${SHARED_PLATFORM_ACTION:-apply}"
shared_platform_account="${SHARED_PLATFORM_ACCOUNT:-open-platform-shared}"
shared_platform_manifests="${SHARED_PLATFORM_MANIFESTS:-resources/svc.plus/shared/gcp/open-platform-shared-vault.yaml,resources/svc.plus/shared/gcp/open-platform-shared-observability.yaml,resources/svc.plus/shared/gcp/open-platform-shared-iam.yaml}"
gcp_iac_ref="${GCP_IAC_REF:-main}"
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

case "${shared_platform_action}" in
  none|plan|apply) ;;
  *)
    echo "::error::SHARED_PLATFORM_ACTION must be none, plan, or apply." >&2
    exit 2
    ;;
esac

[[ "${shared_platform_account}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
  echo "::error::SHARED_PLATFORM_ACCOUNT must be a valid GCP project/account ID." >&2
  exit 2
}

IFS=',' read -r -a shared_platform_manifest_list <<< "${shared_platform_manifests}"
[[ "${#shared_platform_manifest_list[@]}" -gt 0 ]] || {
  echo "::error::SHARED_PLATFORM_MANIFESTS must contain at least one manifest." >&2
  exit 2
}
for shared_platform_manifest in "${shared_platform_manifest_list[@]}"; do
  [[ "${shared_platform_manifest}" == resources/*/shared/gcp/*.yaml && "${shared_platform_manifest}" != *..* ]] || {
    echo "::error::invalid shared GitOps GCP manifest: ${shared_platform_manifest}" >&2
    exit 2
  }
done

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

dispatch_shared_platform() {
  [[ "${shared_platform_action}" == none ]] && {
    echo "Skipping open-platform-shared GCP Terraform action (SHARED_PLATFORM_ACTION=none)."
    return 0
  }

  local shared_platform_manifest run_url
  for shared_platform_manifest in "${shared_platform_manifest_list[@]}"; do
    run_url="$(gh workflow run gcp-iac-pipeline.yml \
      --repo "${target_repo}" \
      --ref main \
      -f "deploy_action=${shared_platform_action}" \
      -f vault_env_path=shared \
      -f github_environment=prod \
      -f "gcp_account_id=${shared_platform_account}" \
      -f gitops_repo_ref=main \
      -f "iac_ref=${gcp_iac_ref}" \
      -f "gcp_resource_manifest=${shared_platform_manifest}")"
    echo "Dispatched open-platform-shared ${shared_platform_manifest} GCP Terraform ${shared_platform_action}: ${run_url}"
    wait_for_run "${run_url}" "open-platform-shared ${shared_platform_manifest}" "${selfhost_wait_timeout_seconds}"
  done
}

dispatch_shared_platform

hybrid_workflow="${HYBRID_WORKFLOW:-hybrid-orchestrator.yml}"
hybrid_run_url="$(gh workflow run "${hybrid_workflow}" \
  --repo "${target_repo}" \
  --ref main \
  -f operation=deploy \
  -f target_domains=all \
  -f "deploy_tag=${snapshot_tag}" \
  -f source_ref=main \
  -f runner_type=ubuntu-latest \
  -f vault_env_path=uat \
  -f target_domain_base=onwalk.net \
  -f observability_endpoint=https://observability.svc.plus \
  -f "akamai_account=${akamai_account}" \
  -f "aws_account=${aws_account}" \
  -f "gcp_account=${gcp_account}" \
  -f "existing_account=ucloud-ulighthost" \
  -f routing_mode=selfhost-first \
  -f vault_addr=https://vault.svc.plus \
  -f xconnect_gateway_ref=tw-xconnect.svc.plus)"
echo "Dispatched UAT Hybrid Orchestrator for ${snapshot_tag}: ${hybrid_run_url}"
wait_for_run "${hybrid_run_url}" "hybrid" "${selfhost_wait_timeout_seconds}"
