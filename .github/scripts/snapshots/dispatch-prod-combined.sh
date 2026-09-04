#!/usr/bin/env bash
set -euo pipefail

# Production counterpart to dispatch-uat-combined.sh. This script is called
# only after the production Environment approval. Both orchestrators run from
# the immutable control-plane release tag. This keeps the GitHub OIDC `ref`
# claim inside Vault's narrow PROD role binding (`refs/tags/v*`) as well as
# pinning every component to the release tag.
gh_token="${GH_TOKEN:?GH_TOKEN must be set}"
release_tag="${RELEASE_TAG:?RELEASE_TAG must be set}"
repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"

[[ "${release_tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::RELEASE_TAG must be a formal immutable v* release tag." >&2
  exit 2
}

export GH_TOKEN="${gh_token}"

# A production daily snapshot publishes the immutable application artifacts.
# Database migration is a separate, explicitly approved operation: the
# migration workflow requires a dedicated source SSH key that is intentionally
# provisioned only when the production source contract is ready. Keeping it
# out of the routine release prevents a missing migration secret from blocking
# an otherwise healthy production deployment.
serverless_url="$(gh workflow run serverless-orchestrator.yml --repo "${repo}" --ref "${release_tag}" \
  -f operation=deploy -f target_domains=web-saas -f vault_env_path=prod \
  -f "tag_ref=${release_tag}" -f deploy_cloudflare=true -f deploy_cloud_run=true \
  -f dns_mode=none -f supabase_target_existing_strategy=reject \
  -f supabase_target_confirm_replace=false | tail -n 1)"
serverless_id="${serverless_url##*/}"
echo "Dispatched production serverless deployment: ${serverless_url}"
gh run watch "${serverless_id}" --repo "${repo}" --exit-status --compact

selfhost_url="$(gh workflow run selfhost-orchestrator.yml --repo "${repo}" --ref "${release_tag}" \
  -f operation=deploy -f vault_env_path=prod -f target_domains=agent-proxy \
  -f cloud_provider=aws-cloud -f agent_proxy_plan=2C1G \
  -f "deploy_tag=${release_tag}" \
  -f source_host=install.svc.plus -f source_domain_base=svc.plus \
  -f target_domain_base=svc.plus -f dns_mode=prod-cutover \
  -f agent_controller_url=https://accounts-serverless-prod.svc.plus | tail -n 1)"
echo "Dispatched AWS T4g.micro (2C1G) deletion-protected production Agent Proxy deployment: ${selfhost_url}"
