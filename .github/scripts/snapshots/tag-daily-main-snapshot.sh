#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../platform-ops/provision/common_require_env.sh"
require_env GH_TOKEN DEPLOY_ENV
. "$(dirname "${BASH_SOURCE[0]}")/snapshot-tag-policy.sh"

tag="$(resolve_and_validate_snapshot_tag)"
export SNAPSHOT_TAG="${tag}"
# 自动 schedule 使用 daily-build-*；人工 workflow_dispatch 也允许
# uat-daily-build-* 和受控 v* release tag。tag 与环境必须配对:
# daily/uat tag -> sit|uat, v* -> prod.
#
# 1. 各 service 仓 CI 的 release job 条件是
#      contains(github.ref, 'daily-build-')
#    日常 tag 不含这一段时, job 直接 skipped, 但整个 run 仍报 success —— UAT
#    快照随后收不到 release-manifest.json。稳定 v* 发布不依赖这个 daily-only
#    manifest, 由构建 Run 成功作为稳定制品构建证据。
#
# 2. v* 只能与 prod 配对，且代表人工控制的稳定发布；daily/uat tag 只能进入
#    sit/uat。前置 job 会在矩阵启动前拒绝错误组合，不让跨仓 tag 操作先发生。
#
# 默认值本来就满足 daily-build-*; 这里挡的是显式传参绕过规则的情况。
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
[[ "${snapshot_organization}" =~ ^ai-workspace-(infra|lab|services|xstream)$ ]] || {
  echo "::error::SNAPSHOT_ORGS must name the current matrix organization (got: ${snapshot_organization:-empty})" >&2
  exit 2
}

configured_repos="$(jq -r '.repositories[].repository' "${build_config}")"
build_repos="$(awk -F/ -v org="${snapshot_organization}" '$1 == org' <<< "${configured_repos}")"

if [[ -n "${SNAPSHOT_REPOS:-}" ]]; then
  requested_repos="$(tr ',' '\n' <<< "${SNAPSHOT_REPOS}")"
  build_repos="$(comm -12 \
    <(sort -u <<< "${build_repos}") \
    <(sort -u <<< "${requested_repos}"))"
  tag_repos="$(awk -F/ -v org="${snapshot_organization}" '$1 == org' <<< "${requested_repos}")"
else
  tag_repos="${build_repos}"
fi

# Infra and xstream currently own no active daily-build target.  Leave an
# empty status artifact so the matrix summary remains deterministic, but do
# not enumerate and tag all of their repositories.
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
