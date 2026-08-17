#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../platform-ops/provision/common_require_env.sh"
require_env GH_TOKEN DEPLOY_ENV

tag="${SNAPSHOT_TAG:-daily-build-$(date -u +%Y.%m.%d)}"
tag="$(printf '%s' "${tag}" | tr -d '\r\n' | xargs)"
export SNAPSHOT_TAG="${tag}"
[[ "${tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo "::error::Invalid snapshot tag: ${tag}" >&2
  exit 2
}
# 自动 schedule 使用 daily-build-*；人工 workflow_dispatch 也允许
# uat-daily-build-* 和受控 v* release tag。tag 与环境必须配对:
# daily/uat tag -> sit|uat, v* -> prod.
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
# 默认值本来就满足 daily-build-*; 这里挡的是显式传参绕过规则的情况。
case "${tag}" in
  v[0-9A-Za-z._/-]*)
    [[ "${DEPLOY_ENV}" == prod ]] || {
      echo "::error::v* release tags require deploy_env=prod; release publication is manually controlled." >&2
      exit 2
    }
    ;;
  daily-build-[0-9A-Za-z._/-]*|uat-daily-build-[0-9A-Za-z._/-]*)
    [[ "${DEPLOY_ENV}" =~ ^(sit|uat)$ ]] || {
      echo "::error::daily-build-* and uat-daily-build-* require deploy_env=sit or uat; use v* with prod for a release." >&2
      exit 2
    }
    ;;
  *)
    echo "::error::Snapshot tag must match daily-build-*, uat-daily-build-*, or a controlled v* release tag." >&2
    exit 2
    ;;
esac

echo "Creating main snapshot ${tag} for ${DEPLOY_ENV}."
if [[ -n "${SNAPSHOT_STATUS_FILE:-}" ]]; then
  mkdir -p "$(dirname "${SNAPSHOT_STATUS_FILE}")"
  : > "${SNAPSHOT_STATUS_FILE}"
fi

# The scheduled snapshot is limited to the active build inventory below.  It
# used to tag every non-archived repository in each organization before this
# point, which could invoke unrelated legacy workflows.
build_config="${GITHUB_WORKSPACE:-.}/.github/daily-snapshot-builds.json"
[[ -f "${build_config}" ]] || {
  echo "::error::Missing daily snapshot build configuration: ${build_config}" >&2
  exit 2
}

# Each matrix job owns a single organization and must never tag or wait for
# every repository in the other organizations.  The build inventory is the
# canonical scheduled-snapshot scope; it prevents unrelated/stale repositories
# from receiving a daily tag merely because they still have a main branch.
snapshot_organization="${SNAPSHOT_ORGS:-}"
[[ "${snapshot_organization}" =~ ^ai-workspace-(infra|lab|service|services|xstream)$ ]] || {
  echo "::error::SNAPSHOT_ORGS must name the current matrix organization (got: ${snapshot_organization:-empty})" >&2
  exit 2
}

# The exporter is a UAT/SIT build input. It must not receive a production
# release tag because PROD consumes the upstream compatibility binary instead.
# Keep environment eligibility in the canonical inventory so an explicit
# repository filter cannot accidentally bypass it.
configured_repos="$(jq -r --arg env "${DEPLOY_ENV}" '
  .repositories[]
  | select(((.environments // ["sit", "uat", "prod"]) | index($env)) != null)
  | .repository
' "${build_config}")"
build_repos="$(awk -F/ -v org="${snapshot_organization}" '$1 == org' <<< "${configured_repos}")"

if [[ -n "${SNAPSHOT_REPOS:-}" ]]; then
  requested_repos="$(tr ',' '\n' <<< "${SNAPSHOT_REPOS}")"
  build_repos="$(comm -12 \
    <(sort -u <<< "${build_repos}") \
    <(sort -u <<< "${requested_repos}"))"
  # Explicit selection narrows the canonical inventory; it must never widen
  # it past the environment-eligible repositories.
  tag_repos="${build_repos}"
else
  tag_repos="${build_repos}"
fi

# Infra currently owns no active daily-build target. Leave an empty status
# artifact so the matrix summary remains deterministic, but do not enumerate
# and tag all of its repositories.
if [[ -z "${tag_repos}" ]]; then
  echo "No active snapshot repositories for ${snapshot_organization}; skipping tag and CI wait."
  exit 0
fi

tag_repos="$(paste -sd, - <<< "${tag_repos}")"
args=(--tag "${tag}" --ref "${SNAPSHOT_REF:-main}" --deploy-env "${DEPLOY_ENV}" --apply
  --org "${snapshot_organization}" --repo "${tag_repos}")
bash docs/tasks/tag-ai-workspace-mains.sh "${args[@]}"

# Most build repositories start from the tag push.  xworkmate-bridge only
# accepts v* tag pushes, so dispatch it explicitly after its immutable daily
# tag is present.  Reuse the centralized dispatcher to keep its inputs in one
# place and avoid dispatching a duplicate build for push-triggered services.
dispatch_repos="$(jq -r \
  --arg org "${snapshot_organization}" \
  --arg selected "${tag_repos}" \
  '[.repositories[]
    | select(.trigger == "workflow_dispatch")
    | select(.repository | startswith($org + "/"))
    | select(.repository as $repo | ($selected | split(",") | index($repo)))
    | .repository] | .[]' \
  "${build_config}")"
if [[ -n "${dispatch_repos}" ]]; then
  dispatch_repos="$(paste -sd, - <<< "${dispatch_repos}")"
  bash docs/tasks/tag-ai-workspace-mains.sh \
    --tag "${tag}" \
    --ref "${SNAPSHOT_REF:-main}" \
    --deploy-env "${DEPLOY_ENV}" \
    --org "${snapshot_organization}" \
    --repo "${dispatch_repos}" \
    --apply \
    --build
fi

if [[ -n "${build_repos}" ]]; then
  build_repos="$(paste -sd, - <<< "${build_repos}")"
  SNAPSHOT_ORGANIZATION="${snapshot_organization}" \
    SNAPSHOT_REPOS="${build_repos}" \
    "$(dirname "${BASH_SOURCE[0]}")/wait-daily-snapshot-builds.sh"
else
  echo "No build-target repositories selected; skipping CI wait."
fi
