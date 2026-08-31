#!/usr/bin/env bash
set -euo pipefail

# Production counterpart to dispatch-uat-combined.sh. This script is called
# only after the production Environment approval. The orchestrator workflows
# run from protected main, while their deploy inputs pin every component to
# the immutable release tag created in target repos.
gh_token="${GH_TOKEN:?GH_TOKEN must be set}"
release_tag="${RELEASE_TAG:?RELEASE_TAG must be set}"
repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"

[[ "${release_tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::RELEASE_TAG must be a formal immutable v* release tag." >&2
  exit 2
}

export GH_TOKEN="${gh_token}"

# The release gate includes the same explicit database migration stage as UAT.
# The reusable migration workflow owns its backup and target checks.
serverless_url="$(gh workflow run serverless-orchestrator.yml --repo "${repo}" --ref main \
  -f operation=deploy+migrate -f target_domains=web-saas -f vault_env_path=prod \
  -f "tag_ref=${release_tag}" -f deploy_cloudflare=true -f deploy_cloud_run=true \
  -f dns_mode=none -f supabase_target_existing_strategy=reject \
  -f supabase_target_confirm_replace=false | tail -n 1)"
serverless_id="${serverless_url##*/}"
echo "Dispatched production serverless deployment: ${serverless_url}"
gh run watch "${serverless_id}" --repo "${repo}" --exit-status --compact

selfhost_url="$(gh workflow run selfhost-orchestrator.yml --repo "${repo}" --ref main \
  -f operation=deploy -f vault_env_path=prod -f target_domains=web-saas \
  -f cloud_provider=vultr-vps -f "deploy_tag=${release_tag}" \
  -f source_host=install.svc.plus -f source_domain_base=svc.plus \
  -f target_domain_base=svc.plus -f dns_mode=none | tail -n 1)"
echo "Dispatched deletion-protected production selfhost deployment: ${selfhost_url}"
