#!/usr/bin/env bash
set -euo pipefail

# Production counterpart to dispatch-uat-combined.sh. This script is called
# only after the production Environment approval. Both orchestrators run from
# the immutable control-plane release tag. This keeps the GitHub OIDC `ref`
# claim inside Vault's narrow PROD role binding (`refs/tags/v*`) as well as
# pinning every component to the release tag.
gh_token="${GH_TOKEN:?GH_TOKEN must be set}"
release_tag="${RELEASE_TAG:?RELEASE_TAG must be set}"
skip_stripe_catalog="${SKIP_STRIPE_CATALOG:-false}"
repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"

[[ "${release_tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::RELEASE_TAG must be a formal immutable v* release tag." >&2
  exit 2
}

export GH_TOKEN="${gh_token}"

# GitHub may accept a workflow_dispatch request while a just-created tag is
# still propagating. Refuse to dispatch unless the tag exists and the created
# run resolves back to that exact tag; otherwise a PROD job can silently run
# from main and fail its protected-ref validation.
tag_ref_path="repos/${repo}/git/ref/tags/${release_tag}"
tag_sha=""
for attempt in {1..15}; do
  tag_sha="$(gh api "${tag_ref_path}" --jq '.object.sha' 2>/dev/null || true)"
  [[ -n "${tag_sha}" ]] && break
  sleep 2
done
if [[ -z "${tag_sha}" ]]; then
  echo "::error::Release tag ${release_tag} is not visible through the GitHub refs API; refusing to dispatch PROD." >&2
  exit 1
fi

dispatch_and_assert_ref() {
  local workflow="$1"
  shift
  local dispatch_url=""
  local run_id=""
  local actual_ref=""

  dispatch_url="$(gh workflow run "${workflow}" --repo "${repo}" --ref "${release_tag}" "$@" | tail -n 1)"
  run_id="${dispatch_url##*/}"
  for attempt in {1..15}; do
    actual_ref="$(gh run view "${run_id}" --repo "${repo}" --json headBranch --jq '.headBranch' 2>/dev/null || true)"
    [[ "${actual_ref}" == "${release_tag}" ]] && break
    sleep 2
  done
  if [[ "${actual_ref}" != "${release_tag}" ]]; then
    echo "::error::${workflow} run ${run_id} resolved to ref '${actual_ref:-unset}', expected '${release_tag}'; refusing PROD deployment." >&2
    return 1
  fi
  printf '%s\n' "${dispatch_url}"
}

# A production daily snapshot publishes the immutable application artifacts.
# Database migration is a separate, explicitly approved operation: the
# migration workflow requires a dedicated source SSH key that is intentionally
# provisioned only when the production source contract is ready. Keeping it
# out of the routine release prevents a missing migration secret from blocking
# an otherwise healthy production deployment.
serverless_url="$(dispatch_and_assert_ref serverless-orchestrator.yml \
  -f operation=deploy -f target_domains=web-saas -f vault_env_path=prod \
  -f "tag_ref=${release_tag}" -f deploy_cloudflare=true -f deploy_cloud_run=true \
  -f dns_mode=prod-cutover -f supabase_target_existing_strategy=reject \
  -f supabase_target_confirm_replace=false -f skip_stripe_catalog="${skip_stripe_catalog}" | tail -n 1)"
serverless_id="${serverless_url##*/}"
echo "Dispatched production serverless deployment: ${serverless_url}"
gh run watch "${serverless_id}" --repo "${repo}" --exit-status --compact

selfhost_url="$(dispatch_and_assert_ref selfhost-orchestrator.yml \
  -f operation=deploy -f vault_env_path=prod -f target_domains=agent-proxy \
  -f cloud_provider=aws-cloud -f agent_proxy_plan=2C1G \
  -f "deploy_tag=${release_tag}" \
  -f source_host=install.svc.plus -f source_domain_base=svc.plus \
  -f target_domain_base=svc.plus -f dns_mode=prod-cutover \
  -f agent_controller_url=https://accounts-serverless-prod.svc.plus | tail -n 1)"
echo "Dispatched production Agent Proxy pool (Tokyo t4g.micro on-demand + US t4g.micro Spot/60m): ${selfhost_url}"
