#!/usr/bin/env bash
set -euo pipefail

# Create one immutable snapshot tag on the platform delivery and application
# repositories that must agree on one reproducible environment point.
# Other infrastructure, docs, and configuration repositories are excluded.

TAG=""
APPLY=false
DEPLOY_ENV="uat"
SNAPSHOT_REPOS=(
  ai-workspace-infra/gitops
  ai-workspace-infra/playbooks
  ai-workspace-infra/iac_modules
  ai-workspace-infra/platform-ops-toolkit
  ai-workspace-lab/xworkspace-console
  ai-workspace-services/docs/
  ai-workspace-services/accounts
  ai-workspace-services/portal
  ai-workspace-services/billing-service
  ai-workspace-services/postgresql.svc.plus
)

declare -A BUILD_WORKFLOWS=(
  [ai-workspace-services/accounts]="ci-pipeline.yml"
  [ai-workspace-services/billing-service]="ci-pipeline.yml"
  [ai-workspace-services/docs]="ci-pipeline.yml"
  [ai-workspace-services/portal]="ci-pipeline.yml"
  [ai-workspace-infra/postgresql.svc.plus]="ci-pipeline.yml"
)

usage() {
  cat <<'EOF'
Usage:
  tag-ai-workspace-mains.sh --tag TAG [--apply] [--deploy-env sit|uat|prod]
  tag-ai-workspace-mains.sh --tag TAG [--push] [--deploy-env sit|uat|prod]

Without --apply/--push, print the main SHA and planned tag operation only.
Existing tags are never moved. --apply/--push creates missing lightweight tags.
When --apply/--push creates a tag, the matching image build workflow is
dispatched with the same tag so the repository tag and GHCR image tag stay
aligned.

Default environment resolution:

| Tag pattern | Default env | Why |
|---|---|---|
| `v*` | `prod` | Release tag, should build production images |
| `release/*` | `uat` | Release branch snapshot, still aligned to UAT build flow |
| `sit-*` / `snapshot-*` | `sit` | Explicit test snapshot |
| anything else | `uat` | Safe default for day-to-day platform snapshot tags |

Override with `--deploy-env sit|uat|prod` when you need to force a different
target.
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
    ai-workspace-infra/postgresql.svc.plus)
      gh workflow run "${workflow}" --repo "${repo}" --ref "${tag}" \
        -f "image_tag=${tag}" \
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
    --deploy-env)
      [[ $# -ge 2 ]] || { echo "--deploy-env requires a value" >&2; exit 2; }
      DEPLOY_ENV="$2"
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

if [[ "${DEPLOY_ENV}" == "uat" ]]; then
  DEPLOY_ENV="$(infer_deploy_env_from_tag "${TAG}")"
fi

[[ "${DEPLOY_ENV}" =~ ^(sit|uat|prod)$ ]] || {
  echo "Invalid deploy env: ${DEPLOY_ENV}" >&2
  exit 2
}

gh auth status >/dev/null

for repo in "${SNAPSHOT_REPOS[@]}"; do
  sha="$(gh api "repos/${repo}/commits/main" --jq .sha)"
  if ref_json="$(gh api "repos/${repo}/git/ref/tags/${TAG}" 2>/dev/null)"; then
    existing="$(jq -r '.object.sha // empty' <<<"${ref_json}")"
  else
    existing=""
  fi

  if [[ -n "${existing}" ]]; then
    if [[ "${existing}" == "${sha}" ]]; then
      printf 'UNCHANGED\t%s\t%s\n' "${repo}" "${sha}"
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
    if [[ -n "${workflow}" ]]; then
      dispatch_build_workflow "${repo}" "${TAG}" "${workflow}" "${DEPLOY_ENV}"
    fi
  fi
done
