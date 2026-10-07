#!/usr/bin/env bash
set -euo pipefail

gh_token="${GH_TOKEN:?GH_TOKEN must be set}"
snapshot_tag="${SNAPSHOT_TAG:?SNAPSHOT_TAG must be set}"
deploy_env="${DEPLOY_ENV:?DEPLOY_ENV must be set}"
workflow="${DISPATCH_WORKFLOW:?DISPATCH_WORKFLOW must be set}"
operation="${DISPATCH_OPERATION:-deploy}"
target_domains="${DISPATCH_TARGET_DOMAINS:-web-saas}"
target_domain_base="${TARGET_DOMAIN_BASE:?TARGET_DOMAIN_BASE must be set}"
target_repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"
skip_stripe_catalog="${SKIP_STRIPE_CATALOG:-false}"
wait_interval_seconds="${DISPATCH_WAIT_INTERVAL_SECONDS:-30}"
wait_timeout_seconds="${DISPATCH_WAIT_TIMEOUT_SECONDS:-10800}"

[[ "${deploy_env}" =~ ^(sit|uat)$ ]] || {
  echo "::error::Daily dispatch only supports sit or uat; got ${deploy_env}." >&2
  exit 2
}
[[ "${snapshot_tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::Refusing to dispatch a non-immutable snapshot tag: ${snapshot_tag}" >&2
  exit 2
}
[[ "${skip_stripe_catalog}" == true || "${skip_stripe_catalog}" == false ]] || {
  echo "::error::SKIP_STRIPE_CATALOG must be true or false." >&2
  exit 2
}
[[ "${wait_interval_seconds}" =~ ^[1-9][0-9]*$ && "${wait_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::Dispatch wait values must be positive integers." >&2
  exit 2
}

args=(workflow run "${workflow}" --repo "${target_repo}" --ref main
  -f "operation=${operation}"
  -f "vault_env_path=${deploy_env}")

case "${workflow}" in
  hybrid-orchestrator.yml)
    [[ "${deploy_env}" == uat ]] || {
      echo "::error::Hybrid Orchestrator is only declared for the selected GitOps UAT hybrid mode." >&2
      exit 2
    }
    args+=(
      -f "target_domains=${target_domains}"
      -f "deploy_tag=${snapshot_tag}"
      -f source_ref=main
      -f runner_type=ubuntu-latest
      -f "target_domain_base=${target_domain_base}"
      -f observability_endpoint=https://observability.svc.plus
      -f routing_mode=selfhost-first
      -f vault_addr=https://vault.svc.plus
      -f xconnect_gateway_ref=tw-xconnect.svc.plus
    )
    ;;
  serverless-orchestrator.yml)
    args+=(
      -f "target_domains=${target_domains}"
      -f "tag_ref=${snapshot_tag}"
      -f deploy_cloudflare=true
      -f deploy_cloud_run=true
      -f "skip_stripe_catalog=${skip_stripe_catalog}"
      -f supabase_target_existing_strategy=accounts_merge
      -f supabase_target_confirm_replace=false
      -f dns_mode=none
    )
    ;;
  *)
    echo "::error::Unsupported environment dispatch workflow: ${workflow}" >&2
    exit 2
    ;;
esac

export GH_TOKEN="${gh_token}"
run_url="$(gh "${args[@]}" | tail -n 1)"
[[ "${run_url}" =~ ^https://github\.com/.*/actions/runs/[1-9][0-9]*$ ]] || {
  echo "::error::Dispatch did not return an exact workflow run URL." >&2
  exit 1
}
echo "run_url=${run_url}" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
echo "Dispatched ${workflow} for ${deploy_env}/${snapshot_tag}: ${run_url}"

RUN_REPOSITORY="${target_repo}" RUN_POLL_INTERVAL_SECONDS="${wait_interval_seconds}" \
  bash "$(dirname "${BASH_SOURCE[0]}")/wait-for-workflow-run.sh" \
  "${run_url}" "${deploy_env} ${workflow}" "${wait_timeout_seconds}"
