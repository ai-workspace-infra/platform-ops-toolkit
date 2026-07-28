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
}

IFS=',' read -r -a repos <<< "$SNAPSHOT_REPOS"
for repo in "${repos[@]}"; do
  workflow="${BUILD_WORKFLOWS[$repo]:-}"
  [[ -n "$workflow" ]] || continue

  run_id=""
  run_sha=""
  while [[ -z "$run_id" && $(date +%s) -lt $deadline ]]; do
    runs="$(gh run list -R "$repo" -w "$workflow" -L 50 --json databaseId,event,status,headBranch,headSha 2>/dev/null || printf '[]')"
    run_id="$(jq -r --arg tag "$SNAPSHOT_TAG" '[.[] | select(.event == "push" and .headBranch == $tag)] | first | .databaseId // empty' <<< "$runs")"
    run_sha="$(jq -r --arg tag "$SNAPSHOT_TAG" '[.[] | select(.event == "push" and .headBranch == $tag)] | first | .headSha // empty' <<< "$runs")"
    [[ -n "$run_id" ]] || sleep "$poll_seconds"
  done

  if [[ -z "$run_id" ]]; then
    record "$repo" "build_timeout" "$run_sha" "no push-triggered CI run found for ${SNAPSHOT_TAG}"
    continue
  fi

  while [[ $(date +%s) -lt $deadline ]]; do
    run="$(gh run view "$run_id" -R "$repo" --json status,conclusion 2>/dev/null || printf '{"status":"unknown","conclusion":"failure"}')"
    status="$(jq -r '.status' <<< "$run")"
    conclusion="$(jq -r '.conclusion // empty' <<< "$run")"
    [[ "$status" == "completed" ]] || { sleep "$poll_seconds"; continue; }
    if [[ "$conclusion" != "success" ]]; then
      record "$repo" "build_failed" "$run_sha" "CI run ${run_id} concluded ${conclusion}"
      break
    fi

    assets="$(gh release view "$SNAPSHOT_TAG" -R "$repo" --json assets --jq '[.assets[].name]' 2>/dev/null || printf '[]')"
    if jq -e 'index("release-manifest.json") != null' <<< "$assets" >/dev/null; then
      release_url="$(gh release view "$SNAPSHOT_TAG" -R "$repo" --json url --jq .url 2>/dev/null || true)"
      record "$repo" "build_succeeded" "$run_sha" "CI run ${run_id}; release manifest ${release_url}"
    else
      record "$repo" "manifest_missing" "$run_sha" "CI run ${run_id} succeeded but release-manifest.json is missing"
    fi
    break
  done
done
