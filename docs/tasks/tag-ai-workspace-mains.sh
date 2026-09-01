#!/usr/bin/env bash
set -euo pipefail

# Create one immutable snapshot tag on repositories selected from the four
# workspace organizations. Repositories whose default branch is not main are skipped.

TAG=""
APPLY=false
TRIGGER_BUILD=false
DEPLOY_ENV="uat"
DEPLOY_ENV_SET=false
SNAPSHOT_REF="main"
ORG_FILTER=""
REPO_FILTER=""
SNAPSHOT_ORGS=(
  ai-workspace-infra
  ai-workspace-lab
  ai-workspace-services
  ai-workspace-xstream
)

workflow_for_repo() {
  case "$1" in
    ai-workspace-services/accounts|ai-workspace-services/billing-service|ai-workspace-services/content-service|ai-workspace-services/portal|ai-workspace-services/postgresql.svc.plus)
      printf '%s\n' ci-pipeline.yml ;;
    ai-workspace-services/edge-gateway) printf '%s\n' deploy.yml ;;
    ai-workspace-lab/xworkmate-bridge) printf '%s\n' pipeline.yml ;;
  esac
}

record_status() {
  local status="$1" repo="$2" sha="$3" detail="$4"
  [[ -n "${SNAPSHOT_STATUS_FILE:-}" ]] || return 0

  jq -cn \
    --arg organization "${ORG_FILTER:-${SNAPSHOT_ORGS:-all}}" \
    --arg repository "${repo}" \
    --arg status "${status}" \
    --arg tag "${TAG}" \
    --arg sha "${sha}" \
    --arg detail "${detail}" \
    '{organization: $organization, repository: $repository, status: $status, tag: $tag, sha: $sha, detail: $detail}' \
    >> "${SNAPSHOT_STATUS_FILE}"
}

usage() {
  cat <<'EOF'
Usage:
  tag-ai-workspace-mains.sh --tag TAG [--apply] [--build] [--ref REF] [--deploy-env sit|uat|prod]
  tag-ai-workspace-mains.sh --tag TAG [--push] [--build] [--ref REF] [--deploy-env sit|uat|prod]
  tag-ai-workspace-mains.sh --tag TAG --org ORG[,ORG...] [--repo ORG/REPO,...]

Without --apply/--push, print the selected ref SHA and planned tag operation only.
Existing tags are never moved. --apply/--push creates missing lightweight tags.
When --build is present, the matching image build workflow is dispatched with
the same tag so the repository tag and GHCR image tag stay aligned. For a
production service build, the workflow definition is dispatched from main and
checks out the immutable tag as its source; this keeps an older promoted tag
from selecting a stale workflow that cannot publish the Cloud Run image.

Default environment resolution:

| Tag pattern | Default env | Why |
|---|---|---|
| `v*` | `prod` | Release tag, should build production images |
| `release/*` | `uat` | Release branch snapshot, still aligned to UAT build flow |
| `sit-*` / `snapshot-*` | `sit` | Explicit test snapshot |
| anything else | `uat` | Safe default for day-to-day platform snapshot tags |

Override with `--deploy-env sit|uat|prod` when you need to force a different
target.

Use `--ref main`, `--ref release/2026.07`, or another branch / commit ref to
explicitly select the source commit for a new immutable tag. If the same tag
already points elsewhere, create a new retry tag such as `TAG-r1`; `--ref`
never moves an existing tag.

All snapshot tags are created from the selected ref SHA for each repository, so
the tag point and the image build trigger stay aligned to the same commit.

`--build` is optional so you can still use this script as a pure tag planner.

By default all non-archived repositories in these organizations are selected:
ai-workspace-infra ai-workspace-lab ai-workspace-services ai-workspace-xstream
Use `--org` to select one or more organizations and `--repo` to select exact
repositories. Exact repositories must use the `ORG/REPO` form.
EOF
}

infer_deploy_env_from_tag() {
  case "$1" in
    v* )
      echo "prod"
      ;;
    release/* )
      echo "uat"
      ;;
    sit-*|snapshot-* )
      echo "sit"
      ;;
    uat-*|uat/* )
      echo "uat"
      ;;
    prod-*|prod/* )
      echo "prod"
      ;;
    *)
      echo "uat"
      ;;
  esac
}

dispatch_build_workflow() {
  local repo="$1"
  local tag="$2"
  local workflow="$3"
  local deploy_env="$4"

  printf 'DISPATCH\t%s\t%s\t%s\n' "${repo}" "${workflow}" "${tag}"

  dispatch_and_wait_for_production() {
    local dispatch_output run_url run_id
    dispatch_output="$(gh workflow run "$@")"
    run_url="$(grep -Eo 'https://github\.com/[^[:space:]]+/actions/runs/[0-9]+' <<<"${dispatch_output}" | tail -n 1)"
    [[ -n "${run_url}" ]] || {
      echo "::error::GitHub did not return the production workflow run URL for ${repo}." >&2
      return 1
    }
    run_id="${run_url##*/}"
    gh run watch "${run_id}" --repo "${repo}" --compact --exit-status
  }

  case "${repo}" in
    ai-workspace-lab/xworkmate-bridge)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        -f "environment=${deploy_env}" \
        -f "run_apply=false" \
        >/dev/null
      ;;
    ai-workspace-services/postgresql.svc.plus)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        -f "image_tag=${tag}" \
        -f "deployment_environment=${deploy_env}" \
        -f "push_latest=false" \
        >/dev/null
      ;;
    ai-workspace-services/accounts)
      if [[ "${deploy_env}" == prod ]]; then
        dispatch_and_wait_for_production "${workflow}" --repo "${repo}" --ref main \
          -f "deploy_env=${deploy_env}" \
          -f "source_ref=${tag}" \
          -f "image_tag=${tag}"
      else
        gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
          -f "deploy_env=${deploy_env}" \
          >/dev/null
      fi
      ;;
    ai-workspace-services/billing-service|ai-workspace-services/content-service)
      if [[ "${deploy_env}" == prod ]]; then
        dispatch_and_wait_for_production "${workflow}" --repo "${repo}" --ref main \
          -f "deployment_environment=${deploy_env}" \
          -f "source_ref=${tag}" \
          -f "image_tag=${tag}"
      else
        gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
          -f "deployment_environment=${deploy_env}" \
          >/dev/null
      fi
      ;;
    ai-workspace-services/edge-gateway)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        >/dev/null
      ;;
    *)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        -f "deployment_environment=${deploy_env}" \
        >/dev/null
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { echo "--tag requires a value" >&2; exit 2; }
      TAG="$2"
      shift 2
      ;;
    --apply|--push)
      APPLY=true
      shift
      ;;
    --build)
      TRIGGER_BUILD=true
      shift
      ;;
    --deploy-env)
      [[ $# -ge 2 ]] || { echo "--deploy-env requires a value" >&2; exit 2; }
      DEPLOY_ENV="$2"
      DEPLOY_ENV_SET=true
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || { echo "--ref requires a value" >&2; exit 2; }
      SNAPSHOT_REF="$2"
      shift 2
      ;;
    --org|--orgs)
      [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
      ORG_FILTER="$2"
      shift 2
      ;;
    --repo|--repos)
      [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
      REPO_FILTER="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${TAG}" ]] || { echo "--tag is required" >&2; exit 2; }
[[ "${TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
  echo "Invalid tag: ${TAG}" >&2
  exit 2
}

if [[ "${DEPLOY_ENV_SET}" == false ]]; then
  DEPLOY_ENV="$(infer_deploy_env_from_tag "${TAG}")"
fi

[[ "${DEPLOY_ENV}" =~ ^(sit|uat|prod)$ ]] || {
  echo "Invalid deploy env: ${DEPLOY_ENV}" >&2
  exit 2
}

gh auth status >/dev/null

IFS=',' read -r -a selected_orgs <<< "${ORG_FILTER:-${SNAPSHOT_ORGS[*]}}"
if [[ -z "${ORG_FILTER}" ]]; then
  selected_orgs=("${SNAPSHOT_ORGS[@]}")
fi

for org in "${selected_orgs[@]}"; do
  [[ " ${SNAPSHOT_ORGS[*]} " == *" ${org} "* ]] || {
    echo "Unsupported organization: ${org}" >&2
    exit 2
  }
done

SNAPSHOT_REPOS=()
if [[ -n "${REPO_FILTER}" ]]; then
  IFS=',' read -r -a SNAPSHOT_REPOS <<< "${REPO_FILTER}"
else
  for org in "${selected_orgs[@]}"; do
    while IFS= read -r repo; do
      [[ -n "${repo}" ]] && SNAPSHOT_REPOS+=("${repo}")
    done < <(gh api --paginate "orgs/${org}/repos?per_page=100&type=all" \
      --jq '.[] | select(.archived == false) | .full_name')
  done
fi

[[ "${#SNAPSHOT_REPOS[@]}" -gt 0 ]] || {
  echo "No repositories selected." >&2
  exit 2
}

for repo in "${SNAPSHOT_REPOS[@]}"; do
  [[ "${repo}" == */* ]] || {
    echo "Repository must use ORG/REPO form: ${repo}" >&2
    exit 2
  }
  owner="${repo%%/*}"
  [[ " ${selected_orgs[*]} " == *" ${owner} "* ]] || {
    if [[ "${SNAPSHOT_FILTER_BY_ORG:-false}" == "true" ]]; then
      printf 'SKIP\t%s\tnot owned by selected matrix organization\n' "${repo}"
      record_status "skipped" "${repo}" "" "not owned by selected matrix organization"
      continue
    fi
    echo "Repository ${repo} is outside the selected organizations." >&2
    exit 2
  }
  default_branch="$(gh api "repos/${repo}" --jq .default_branch)"
  [[ "${default_branch}" == "main" ]] || {
    printf 'SKIP\t%s\tdefault branch is %s, not main\n' "${repo}" "${default_branch}"
    record_status "skipped" "${repo}" "" "default branch is ${default_branch}, not main"
    continue
  }
  if ! sha="$(gh api "repos/${repo}/commits/${SNAPSHOT_REF}" --jq .sha 2>/dev/null)" || [[ -z "${sha}" ]]; then
    printf 'SKIP\t%s\tno commit found for ref %s\n' "${repo}" "${SNAPSHOT_REF}"
    record_status "skipped" "${repo}" "" "no commit for ref ${SNAPSHOT_REF}"
    continue
  fi
  if ref_json="$(gh api "repos/${repo}/git/ref/tags/${TAG}" 2>/dev/null)"; then
    existing="$(jq -r '.object.sha // empty' <<<"${ref_json}")"
  else
    existing=""
  fi

  if [[ -n "${existing}" ]]; then
    if [[ "${existing}" == "${sha}" ]]; then
      printf 'UNCHANGED\t%s\t%s\n' "${repo}" "${sha}"
      record_status "unchanged" "${repo}" "${sha}" "tag already points to selected ref"
      workflow="$(workflow_for_repo "${repo}")"
      if [[ -n "${workflow}" && "${APPLY}" == true && "${TRIGGER_BUILD}" == true ]]; then
        dispatch_build_workflow "${repo}" "${TAG}" "${workflow}" "${DEPLOY_ENV}"
        record_status "dispatched" "${repo}" "${sha}" "workflow ${workflow} dispatched"
      fi
      continue
    fi
    printf 'SKIP\t%s\ttag %s already points to %s; ref %s is %s (use a new immutable tag, for example %s-r1)\n' \
      "${repo}" "${TAG}" "${existing}" "${SNAPSHOT_REF}" "${sha}" "${TAG}"
    record_status "skipped" "${repo}" "${sha}" "tag already points to a different commit"
    continue
  fi

  printf '%s\t%s\t%s\n' "$([[ "${APPLY}" == true ]] && echo CREATE || echo PLAN)" "${repo}" "${sha}"
  if [[ "${APPLY}" == true ]]; then
    tag_response_file="$(mktemp)"
    if ! gh api --include --method POST "repos/${repo}/git/refs" \
      -f "ref=refs/tags/${TAG}" \
      -f "sha=${sha}" >"${tag_response_file}" 2>&1; then
      tag_diagnostics="$(awk '
        BEGIN { IGNORECASE = 1 }
        /^(HTTP\/|x-accepted-github-permissions:|x-github-request-id:)/ {
          gsub(/\r/, "")
          print
        }
      ' "${tag_response_file}" | paste -sd ';' -)"
      tag_message="$(sed -n '/^\r\{0,1\}$/,$p' "${tag_response_file}" | jq -r '.message // empty' 2>/dev/null || true)"
      [[ -n "${tag_message}" ]] && printf 'gh: %s\n' "${tag_message}" >&2
      [[ -n "${tag_diagnostics}" ]] && printf 'GitHub API diagnostics: %s\n' "${tag_diagnostics}" >&2
      tag_detail="GitHub App denied tag creation"
      [[ -n "${tag_diagnostics}" ]] && tag_detail+="; ${tag_diagnostics}"
      record_status "failed" "${repo}" "${sha}" "${tag_detail}"
      rm -f "${tag_response_file}"
      echo "::error::GitHub App denied tag creation for ${repo} (${TAG}). Verify the daily-snapshot-tag installation access and any organization tag ruleset/bypass actor for refs/tags/v*." >&2
      exit 1
    fi
    rm -f "${tag_response_file}"

    record_status "created" "${repo}" "${sha}" "tag created"

    workflow="$(workflow_for_repo "${repo}")"
    if [[ -n "${workflow}" && "${TRIGGER_BUILD}" == true ]]; then
      dispatch_build_workflow "${repo}" "${TAG}" "${workflow}" "${DEPLOY_ENV}"
      record_status "dispatched" "${repo}" "${sha}" "workflow ${workflow} dispatched"
    fi
  else
    record_status "planned" "${repo}" "${sha}" "tag creation planned"
  fi
done
