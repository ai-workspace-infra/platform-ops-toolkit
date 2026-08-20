#!/usr/bin/env bash
set -euo pipefail

gh_token="${GH_TOKEN:?GH_TOKEN must be set}"
snapshot_tag="${SNAPSHOT_TAG:?SNAPSHOT_TAG must be set}"
target_repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"
workflow_file="${TARGET_WORKFLOW:-serverless-orchestrator.yml}"

[[ "${snapshot_tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::Refusing to dispatch UAT with a non-immutable snapshot tag: ${snapshot_tag}" >&2
  exit 2
}

export GH_TOKEN="${gh_token}"
gh workflow run "${workflow_file}" \
  --repo "${target_repo}" \
  --ref main \
  -f operation=deploy+migrate \
  -f vault_env_path=uat \
  -f "tag_ref=${snapshot_tag}" \
  -f deploy_cloudflare=true \
  -f deploy_cloud_run=true \
  -f supabase_target_existing_strategy=accounts_merge \
  -f supabase_target_confirm_replace=false

echo "Dispatched UAT serverless deploy+migrate for ${snapshot_tag}."
