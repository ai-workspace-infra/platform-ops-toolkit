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
skip_stripe_catalog="${SKIP_STRIPE_CATALOG:-false}"
enable_migration="${ENABLE_MIGRATION:-false}"
apply_accounts_schema_migration="${APPLY_ACCOUNTS_SCHEMA_MIGRATION:-false}"
adopt_accounts_baseline="${ADOPT_ACCOUNTS_BASELINE:-false}"
accounts_source_backend="${ACCOUNTS_SOURCE_BACKEND:-supabase}"
serverless_operation="${SERVERLESS_OPERATION:-}"
wait_timeout_seconds="${UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS:-3600}"
wait_interval_seconds="${UAT_SERVERLESS_WAIT_INTERVAL_SECONDS:-30}"
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

# The Hybrid Orchestrator is the only UAT dispatch target and it has no inputs
# for data migration, Accounts schema migration / baseline adoption or the
# XConnect Lab release overrides. Dropping them would report a green UAT deploy
# that never performed the requested operation, so refuse the request instead.
unsupported_requests=()
[[ "${enable_migration}" == "true" ]] && unsupported_requests+=("enable_migration")
[[ "${apply_accounts_schema_migration}" == "true" ]] && unsupported_requests+=("apply_accounts_schema_migration")
[[ "${adopt_accounts_baseline}" == "true" ]] && unsupported_requests+=("adopt_accounts_baseline")
[[ -n "${xconnect_one_release_override}" ]] && unsupported_requests+=("xconnect_one_release_tag")
[[ -n "${xconnect_gateway_release_override}" ]] && unsupported_requests+=("xconnect_gateway_release_tag")
if [[ "${#unsupported_requests[@]}" -gt 0 ]]; then
  echo "::error::UAT Hybrid deploy cannot carry: ${unsupported_requests[*]}. Refusing to report a deploy that silently skips them; run the explicit migration/XConnect workflow separately." >&2
  exit 2
fi

if [[ "${skip_stripe_catalog}" != "true" ]]; then
  echo "::notice::UAT Hybrid always dispatches its children with skip_stripe_catalog=true; the Stripe catalog is not synchronized by this run."
fi

export GH_TOKEN="${gh_token}"

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
RUN_REPOSITORY="${target_repo}" RUN_POLL_INTERVAL_SECONDS="${wait_interval_seconds}" \
  bash "$(dirname "${BASH_SOURCE[0]}")/wait-for-workflow-run.sh" \
  "${hybrid_run_url}" "UAT Hybrid" "${selfhost_wait_timeout_seconds}"

# Keep the images this successful UAT accepted, verified against the Hybrid
# run's own verdict. PROD may promote nothing else (plan §7, GAP-16, TC-10).
promotion_manifest_file="${UAT_PROMOTION_MANIFEST_FILE:-}"
if [[ -n "${promotion_manifest_file}" ]]; then
  hybrid_run_id="${hybrid_run_url##*/}"
  [[ "${hybrid_run_id}" =~ ^[1-9][0-9]*$ ]] || {
    echo "::error::Cannot resolve the UAT Hybrid run id from ${hybrid_run_url}." >&2
    exit 1
  }
  manifest_work="$(mktemp -d)"
  gh run download "${hybrid_run_id}" --repo "${target_repo}" --name uat-artifact-manifest --dir "${manifest_work}" || {
    echo "::error::UAT Hybrid run ${hybrid_run_id} has no uat-artifact-manifest; nothing can be promoted." >&2
    exit 1
  }
  gh api "repos/${target_repo}/actions/runs/${hybrid_run_id}" > "${manifest_work}/uat-run.json"
  python3 "$(dirname "${BASH_SOURCE[0]}")/verify-promotion-manifest.py" \
    --manifest "${manifest_work}/uat-artifact-manifest.json" --snapshot-tag "${snapshot_tag}" \
    --uat-run-id "${hybrid_run_id}" --uat-run-json "${manifest_work}/uat-run.json" > "${promotion_manifest_file}"
  echo "UAT artifact manifest verified for ${snapshot_tag} (Hybrid run ${hybrid_run_id})."
fi
