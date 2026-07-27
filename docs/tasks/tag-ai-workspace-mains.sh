#!/usr/bin/env bash
set -euo pipefail

# Create one immutable snapshot tag on repositories selected from the four
# workspace organizations. Repositories whose default branch is not main are skipped.

TAG=""
APPLY=false
TRIGGER_BUILD=false
DEPLOY_ENV="uat"
DEPLOY_ENV_SET=false
ORG_FILTER=""
REPO_FILTER=""
SNAPSHOT_ORGS=(
  ai-workspace-infra
  ai-workspace-lab
  ai-workspace-services
  ai-workspace-xstream
)

declare -A BUILD_WORKFLOWS=(
  [ai-workspace-services/accounts]="ci-pipeline.yml"
  [ai-workspace-services/billing-service]="ci-pipeline.yml"
  [ai-workspace-services/docs]="ci-pipeline.yml"
  [ai-workspace-services/portal]="ci-pipeline.yml"
  [ai-workspace-services/postgresql.svc.plus]="ci-pipeline.yml"
)

usage() {
  cat <<'EOF'
Usage:
  tag-ai-workspace-mains.sh --tag TAG [--apply] [--build] [--deploy-env sit|uat|prod]
  tag-ai-workspace-mains.sh --tag TAG [--push] [--build] [--deploy-env sit|uat|prod]
  tag-ai-workspace-mains.sh --tag TAG --org ORG[,ORG...] [--repo ORG/REPO,...]

Without --apply/--push, print the main SHA and planned tag operation only.
Existing tags are never moved. --apply/--push creates missing lightweight tags.
When --build is present, the matching image build workflow is dispatched with
the same tag so the repository tag and GHCR image tag stay aligned.

Default environment resolution:

| Tag pattern | Default env | Why |
|---|---|---|
| `v*` | `prod` | Release tag, should build production images |
| `release/*` | `uat` | Release branch snapshot, still aligned to UAT build flow |
| `sit-*` / `snapshot-*` | `sit` | Explicit test snapshot |
| anything else | `uat` | Safe default for day-to-day platform snapshot tags |

Override with `--deploy-env sit|uat|prod` when you need to force a different
target.

All snapshot tags are created from the current `main` branch SHA for each
repository, so the tag point and the image build trigger stay aligned to the
same mainline commit.

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

  case "${repo}" in
    ai-workspace-services/postgresql.svc.plus)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        -f "image_tag=${tag}" \
        -f "deployment_environment=${deploy_env}" \
        -f "push_latest=false" \
        >/dev/null
      ;;
    ai-workspace-services/accounts)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        -f "deploy_env=${deploy_env}" \
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
    echo "Repository ${repo} is outside the selected organizations." >&2
    exit 2
  }
  if [[ "${repo}" == "${owner}/.github" ]]; then
    printf 'SKIP\t%s\tshared .github repository\n' "${repo}"
    continue
  fi
  default_branch="$(gh api "repos/${repo}" --jq .default_branch)"
  [[ "${default_branch}" == "main" ]] || {
    printf 'SKIP\t%s\tdefault branch is %s, not main\n' "${repo}" "${default_branch}"
    continue
  }
  sha="$(gh api "repos/${repo}/commits/main" --jq .sha)"
  if ref_json="$(gh api "repos/${repo}/git/ref/tags/${TAG}" 2>/dev/null)"; then
    existing="$(jq -r '.object.sha // empty' <<<"${ref_json}")"
  else
    existing=""
  fi

  if [[ -n "${existing}" ]]; then
    if [[ "${existing}" == "${sha}" ]]; then
      printf 'UNCHANGED\t%s\t%s\n' "${repo}" "${sha}"
      workflow="${BUILD_WORKFLOWS[${repo}]:-}"
      if [[ -n "${workflow}" && "${APPLY}" == true && "${TRIGGER_BUILD}" == true ]]; then
        dispatch_build_workflow "${repo}" "${TAG}" "${workflow}" "${DEPLOY_ENV}"
      fi
      continue
    fi
    echo "ERROR: ${repo} already has ${TAG} at ${existing}, main is ${sha}" >&2
    exit 1
  fi

  printf '%s\t%s\t%s\n' "$([[ "${APPLY}" == true ]] && echo CREATE || echo PLAN)" "${repo}" "${sha}"
  if [[ "${APPLY}" == true ]]; then
    gh api --method POST "repos/${repo}/git/refs" \
      -f "ref=refs/tags/${TAG}" \
      -f "sha=${sha}" >/dev/null

    workflow="${BUILD_WORKFLOWS[${repo}]:-}"
    if [[ -n "${workflow}" && "${TRIGGER_BUILD}" == true ]]; then
      dispatch_build_workflow "${repo}" "${TAG}" "${workflow}" "${DEPLOY_ENV}"
    fi
  fi
done
