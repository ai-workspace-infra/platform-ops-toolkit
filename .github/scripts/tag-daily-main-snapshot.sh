#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env GH_TOKEN DEPLOY_ENV

tag="${SNAPSHOT_TAG:-daily-build-$(date -u +%Y.%m.%d)}"
tag="$(printf '%s' "${tag}" | tr -d '\r\n' | xargs)"
export SNAPSHOT_TAG="${tag}"
[[ "${tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo "::error::Invalid snapshot tag: ${tag}" >&2
  exit 2
}
[[ "${DEPLOY_ENV}" =~ ^(sit|uat|prod)$ ]] || {
  echo "::error::Invalid deploy environment: ${DEPLOY_ENV}" >&2
  exit 2
}

echo "Creating main snapshot ${tag} for ${DEPLOY_ENV}."
if [[ -n "${SNAPSHOT_STATUS_FILE:-}" ]]; then
  mkdir -p "$(dirname "${SNAPSHOT_STATUS_FILE}")"
  : > "${SNAPSHOT_STATUS_FILE}"
fi

# Make the source ref explicit; snapshot tags remain immutable.
args=(--tag "${tag}" --ref main --deploy-env "${DEPLOY_ENV}" --apply)
if [[ -n "${SNAPSHOT_ORGS:-}" ]]; then
  args+=(--org "${SNAPSHOT_ORGS}")
fi
if [[ -n "${SNAPSHOT_REPOS:-}" ]]; then
  args+=(--repo "${SNAPSHOT_REPOS}")
fi
bash docs/tasks/tag-ai-workspace-mains.sh "${args[@]}"

build_repos="${SNAPSHOT_REPOS:-ai-workspace-services/accounts,ai-workspace-services/billing-service,ai-workspace-services/docs,ai-workspace-services/portal,ai-workspace-services/postgresql.svc.plus}"
SNAPSHOT_REPOS="${build_repos}" .github/scripts/wait-daily-snapshot-builds.sh
