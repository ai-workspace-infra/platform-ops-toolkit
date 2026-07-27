#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env GH_TOKEN DEPLOY_ENV

tag="${SNAPSHOT_TAG:-daily-build-$(date -u +%Y.%m.%d)}"
[[ "${tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo "::error::Invalid snapshot tag: ${tag}" >&2
  exit 2
}
[[ "${DEPLOY_ENV}" =~ ^(sit|uat|prod)$ ]] || {
  echo "::error::Invalid deploy environment: ${DEPLOY_ENV}" >&2
  exit 2
}

echo "Creating main snapshot ${tag} for ${DEPLOY_ENV}."
bash docs/tasks/tag-ai-workspace-mains.sh \
  --tag "${tag}" \
  --deploy-env "${DEPLOY_ENV}" \
  --apply \
  --build
