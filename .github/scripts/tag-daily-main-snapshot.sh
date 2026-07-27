#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env GH_TOKEN DEPLOY_ENV

tag="${SNAPSHOT_TAG:-daily-build-$(date -u +%Y.%m.%d)}"
tag="$(printf '%s' "${tag}" | tr -d '\r\n' | xargs)"
[[ "${tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo "::error::Invalid snapshot tag: ${tag}" >&2
  exit 2
}
[[ "${DEPLOY_ENV}" =~ ^(sit|uat|prod)$ ]] || {
  echo "::error::Invalid deploy environment: ${DEPLOY_ENV}" >&2
  exit 2
}

echo "Creating main snapshot ${tag} for ${DEPLOY_ENV}."
args=(--tag "${tag}" --deploy-env "${DEPLOY_ENV}" --apply --build)
if [[ -n "${SNAPSHOT_ORGS:-}" ]]; then
  args+=(--org "${SNAPSHOT_ORGS}")
fi
if [[ -n "${SNAPSHOT_REPOS:-}" ]]; then
  args+=(--repo "${SNAPSHOT_REPOS}")
fi
bash docs/tasks/tag-ai-workspace-mains.sh "${args[@]}"
