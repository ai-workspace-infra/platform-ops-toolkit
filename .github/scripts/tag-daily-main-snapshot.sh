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

# 快照 tag 必须带 daily-build- 这一段。两件事都挂在它上面:
#
# 1. 各 service 仓 CI 的 release job 条件是
#      contains(github.ref, 'daily-build-')
#    不含这一段, job 直接 skipped, 但整个 run 仍报 success —— 快照随后收不到
#    release-manifest.json, 以 manifest_missing 失败。CI 全绿、快照失败, 排查
#    起点离根因很远。
#
# 2. 更要紧的一面: 发布路由把 release 形状的 tag(v*, *-release-*)判给 prod。
#    2026-08-04 用 snapshot_tag=v2026.8.4 跑了一次 uat 快照, tag 打到各仓后,
#    platform-ops-toolkit 被 tag push 拉进了 DEPLOY_ENV=prod 的部署 —— 它没成,
#    唯一的原因是 gitops/compose/web-saas/.env.prod 不存在。一次 UAT 快照不该
#    有任何机会碰到生产, 更不该靠一个缺失的文件兜底。
#
# 默认值本来就满足这条; 这里挡的是显式传参绕过默认值的情况。
[[ "${tag}" == *daily-build-* ]] || {
  echo "::error::Snapshot tag must contain 'daily-build-' (got: ${tag}). Service CI publishes release-manifest.json only for daily-build tags, and release-shaped tags such as v* route the delivery pipeline to prod." >&2
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

build_repos="${SNAPSHOT_REPOS:-ai-workspace-services/accounts,ai-workspace-services/billing-service,ai-workspace-services/content-service,ai-workspace-services/portal,ai-workspace-services/postgresql.svc.plus}"
SNAPSHOT_REPOS="${build_repos}" .github/scripts/wait-daily-snapshot-builds.sh
