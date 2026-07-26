#!/usr/bin/env bash
set -euo pipefail

# Create one immutable snapshot tag on the platform delivery and application
# repositories that must agree on one reproducible environment point.
# Other infrastructure, docs, and configuration repositories are excluded.

TAG=""
APPLY=false
SNAPSHOT_REPOS=(
  ai-workspace-infra/platform-ops-toolkit
  ai-workspace-infra/iac_modules
  ai-workspace-infra/playbooks
  ai-workspace-infra/gitops
  ai-workspace-lab/xworkspace-console
  ai-workspace-services/accounts
  ai-workspace-services/billing-service
  ai-workspace-services/portal
)

usage() {
  cat <<'EOF'
Usage: tag-ai-workspace-mains.sh --tag TAG [--push]

Without --push, print the main SHA and planned tag operation only.
Existing tags are never moved. --push creates missing lightweight tags.
EOF
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
  fi
done
