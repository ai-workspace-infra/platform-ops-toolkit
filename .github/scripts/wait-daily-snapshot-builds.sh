#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env GH_TOKEN SNAPSHOT_TAG SNAPSHOT_REPOS SNAPSHOT_STATUS_FILE

declare -A BUILD_WORKFLOWS=(
  [ai-workspace-services/accounts]=ci-pipeline.yml
  [ai-workspace-services/billing-service]=ci-pipeline.yml
  [ai-workspace-services/docs]=ci-pipeline.yml
  [ai-workspace-services/portal]=ci-pipeline.yml
  [ai-workspace-services/postgresql.svc.plus]=ci-pipeline.yml
)

timeout_seconds="${BUILD_TIMEOUT_SECONDS:-1800}"
poll_seconds="${BUILD_POLL_SECONDS:-15}"
deadline=$(( $(date +%s) + timeout_seconds ))

# 只有 build_succeeded 算通过。其余状态都要让这一步真的失败 ——
# 记进 JSONL 但 exit 0 属于 12 号陷阱(假绿): job ✓ 而镜像根本没构建出来,
# 下游拿着不存在的 tag 去部署才暴露。
failures=()

record() {
  local repo="$1" status="$2" sha="$3" detail="$4"
  jq -cn \
    --arg organization "${repo%%/*}" \
    --arg repository "$repo" \
    --arg status "$status" \
    --arg tag "$SNAPSHOT_TAG" \
    --arg sha "$sha" \
    --arg detail "$detail" \
    '{organization:$organization, repository:$repository, status:$status, tag:$tag, sha:$sha, detail:$detail}' \
    >> "$SNAPSHOT_STATUS_FILE"

  if [[ "$status" != "build_succeeded" ]]; then
    failures+=("${repo}: ${status} — ${detail}")
    echo "::error::${repo} ${status}: ${detail}"
  fi
}

IFS=',' read -r -a repos <<< "$SNAPSHOT_REPOS"
for repo in "${repos[@]}"; do
  workflow="${BUILD_WORKFLOWS[$repo]:-}"
  [[ -n "$workflow" ]] || continue

  run_id=""
  if ! expected_sha="$(gh api "repos/${repo}/commits/${SNAPSHOT_TAG}" --jq .sha 2>/dev/null)" || [[ -z "$expected_sha" ]]; then
    record "$repo" "build_lookup_failed" "" "cannot resolve ${SNAPSHOT_TAG} to a commit"
    continue
  fi
  run_sha="$expected_sha"
  while [[ -z "$run_id" && $(date +%s) -lt $deadline ]]; do
    runs="$(gh run list -R "$repo" -w "$workflow" -L 50 --json databaseId,event,status,headBranch,headSha 2>/dev/null || printf '[]')"
    run_id="$(jq -r \
      --arg tag "$SNAPSHOT_TAG" \
      --arg sha "$expected_sha" \
      '[.[] | select(.event == "push" and .headBranch == $tag and .headSha == $sha)] | first | .databaseId // empty' \
      <<< "$runs")"
    [[ -n "$run_id" ]] || sleep "$poll_seconds"
  done

  if [[ -z "$run_id" ]]; then
    record "$repo" "build_timeout" "$run_sha" "no push-triggered CI run found for ${SNAPSHOT_TAG} at ${expected_sha}"
    continue
  fi

  recorded=false
  while [[ $(date +%s) -lt $deadline ]]; do
    run="$(gh run view "$run_id" -R "$repo" --json status,conclusion 2>/dev/null || printf '{"status":"unknown","conclusion":"failure"}')"
    status="$(jq -r '.status' <<< "$run")"
    conclusion="$(jq -r '.conclusion // empty' <<< "$run")"
    [[ "$status" == "completed" ]] || { sleep "$poll_seconds"; continue; }
    if [[ "$conclusion" != "success" ]]; then
      record "$repo" "build_failed" "$run_sha" "CI run ${run_id} concluded ${conclusion}"
      recorded=true
      break
    fi

    assets="$(gh release view "$SNAPSHOT_TAG" -R "$repo" --json assets --jq '[.assets[].name]' 2>/dev/null || printf '[]')"
    if jq -e 'index("release-manifest.json") != null' <<< "$assets" >/dev/null; then
      release_url="$(gh release view "$SNAPSHOT_TAG" -R "$repo" --json url --jq .url 2>/dev/null || true)"
      record "$repo" "build_succeeded" "$run_sha" "CI run ${run_id}; release manifest ${release_url}"
    else
      record "$repo" "manifest_missing" "$run_sha" "CI run ${run_id} succeeded but release-manifest.json is missing"
    fi
    recorded=true
    break
  done

  # 循环也可能是被 deadline 弹出来的(run 一直没跑完), 那一轮不会写任何
  # 记录。不补这一条, 该仓库在汇总里直接消失, 看起来像"没这个仓库"而不是
  # "等超时了"。
  if [[ "$recorded" != true ]]; then
    record "$repo" "build_timeout" "$run_sha" "CI run ${run_id} still in progress when the ${timeout_seconds}s deadline expired"
  fi
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo "Daily snapshot builds did not all succeed for ${SNAPSHOT_TAG}:" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "All daily snapshot builds succeeded for ${SNAPSHOT_TAG}."
