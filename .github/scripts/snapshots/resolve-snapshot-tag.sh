#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../platform-ops/provision/common_require_env.sh"
require_env DEPLOY_ENV

workspace="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
build_config="${workspace}/.github/daily-snapshot-builds.json"
snapshot_ref="${SNAPSHOT_REF:-main}"
tag="${SNAPSHOT_TAG:-daily-build-$(date -u +%Y.%m.%d)}"
tag="$(printf '%s' "${tag}" | tr -d '\r\n' | xargs)"

[[ "${tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo "::error::Invalid snapshot tag: ${tag}" >&2
  exit 2
}

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

if [[ "${DEPLOY_ENV}" == prod ]]; then
  [[ "${SNAPSHOT_SOURCE_REF:-}" =~ ^(v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?|(daily-build|uat-daily-build)-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?)$ ]] || {
    echo "::error::Prod snapshot_source_ref must be an existing verified v*, daily-build-* or uat-daily-build-* tag; main is not allowed." >&2
    exit 1
  }
fi

[[ -f "${build_config}" ]] || {
  echo "::error::Missing daily snapshot build configuration: ${build_config}" >&2
  exit 2
}

next_snapshot_revision() {
  local current="$1"
  if [[ "${current}" =~ ^(.+)-r([0-9]+)$ ]]; then
    printf '%s-r%s\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]} + 1))"
  else
    printf '%s-r1\n' "${current}"
  fi
}

token_for_repo() {
  case "$1" in
    ai-workspace-infra/*) printf '%s' "${SNAPSHOT_TOKEN_AI_WORKSPACE_INFRA:?missing token for ai-workspace-infra}" ;;
    ai-workspace-lab/*) printf '%s' "${SNAPSHOT_TOKEN_AI_WORKSPACE_LAB:?missing token for ai-workspace-lab}" ;;
    ai-workspace-services/*) printf '%s' "${SNAPSHOT_TOKEN_AI_WORKSPACE_SERVICES:?missing token for ai-workspace-services}" ;;
    ai-workspace-xstream/*) printf '%s' "${SNAPSHOT_TOKEN_AI_WORKSPACE_XSTREAM:?missing token for ai-workspace-xstream}" ;;
    *) echo "::error::Unsupported snapshot repository: $1" >&2; return 2 ;;
  esac
}

gh_for_repo() {
  local repo="$1"; shift
  GH_TOKEN="$(token_for_repo "${repo}")" gh api "$@"
}

resolve_commit() {
  local repo="$1" ref="$2" attempt sha
  for attempt in 1 2 3; do
    sha="$(gh_for_repo "${repo}" "repos/${repo}/commits/${ref}" --jq .sha 2>/dev/null || true)"
    if [[ -n "${sha}" ]]; then
      printf '%s' "${sha}"
      return 0
    fi
    [[ "${attempt}" -lt 3 ]] && sleep "${attempt}"
  done
  return 1
}

repo_selected() {
  local repo="$1"
  [[ -z "${SNAPSHOT_REPOS:-}" ]] && return 0
  tr ',' '\n' <<<"${SNAPSHOT_REPOS}" | grep -Fxq "${repo}"
}

repos=()
while IFS= read -r repo; do
  [[ -n "${repo}" ]] && repos+=("${repo}")
done < <(jq -r --arg env "${DEPLOY_ENV}" '
  .repositories[]
  | select(((.environments // ["sit", "uat", "prod"]) | index($env)) != null)
  | .repository
' "${build_config}")

eligible_repos=()
for repo in "${repos[@]}"; do
  repo_selected "${repo}" || continue
  eligible_repos+=("${repo}")
done

[[ "${#eligible_repos[@]}" -gt 0 ]] || {
  echo "::error::No environment-eligible repositories selected for ${DEPLOY_ENV}." >&2
  exit 2
}

tag_conflict=false
for repo in "${eligible_repos[@]}"; do
  expected_sha="$(resolve_commit "${repo}" "${snapshot_ref}" || true)"
  [[ -n "${expected_sha}" ]] || {
    echo "::error::Cannot resolve ${snapshot_ref} in ${repo}; refusing to choose a release tag." >&2
    exit 1
  }
  existing_sha="$(gh_for_repo "${repo}" "repos/${repo}/git/ref/tags/${tag}" --jq '.object.sha // empty' 2>/dev/null || true)"
  if [[ -n "${existing_sha}" && "${existing_sha}" != "${expected_sha}" ]]; then
    tag_conflict=true
  fi
done

if [[ "${tag_conflict}" == true ]]; then
  candidate="$(next_snapshot_revision "${tag}")"
  while :; do
    occupied=false
    for repo in "${eligible_repos[@]}"; do
      if gh_for_repo "${repo}" "repos/${repo}/git/ref/tags/${candidate}" >/dev/null 2>&1; then
        occupied=true
        break
      fi
    done
    [[ "${occupied}" == false ]] && break
    candidate="$(next_snapshot_revision "${candidate}")"
  done
  echo "::warning::Snapshot tag ${tag} is already bound to a different commit; using immutable revision ${candidate}." >&2
  tag="${candidate}"
fi

echo "Resolved snapshot tag: ${tag} (source ref: ${snapshot_ref}, environment: ${DEPLOY_ENV})"
echo "snapshot_tag=${tag}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
