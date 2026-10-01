#!/usr/bin/env bash
set -euo pipefail

# Promote the exact immutable UAT component tags to a formal v* release tag.
# This script is called only after the UAT Hybrid workflow has completed
# successfully. Existing release tags are never moved.
#
# Every repository of the canonical snapshot organization is promoted, not only
# the repositories that publish a production image: the PROD serverless
# orchestrator checks out portal and frontend-router at the release tag, and
# the direct PROD path tags the whole inventory as well. All UAT tags and any
# existing release tags are verified before the first tag is created. GitHub
# cannot atomically write refs across repositories: an API failure during phase
# 2 stops promotion and PROD dispatch; a rerun verifies and completes missing
# tags without moving or deleting already-created refs.

uat_tag="${UAT_TAG:?UAT_TAG must be set}"
build_config="${BUILD_CONFIG:?BUILD_CONFIG must be set}"
control_plane_sha="${CONTROL_PLANE_SHA:?CONTROL_PLANE_SHA must be set}"
promotion_organization="${PROMOTION_ORGANIZATION:-ai-workspace-services}"
output_file="${GITHUB_OUTPUT:-/dev/stdout}"

. "$(dirname "${BASH_SOURCE[0]}")/read-ref-sha.sh"

[[ "${uat_tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::UAT_TAG must be an immutable daily-build tag: ${uat_tag}" >&2
  exit 2
}
[[ "${control_plane_sha}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::CONTROL_PLANE_SHA must be a full protected workflow SHA." >&2
  exit 2
}
[[ -f "${build_config}" ]] || {
  echo "::error::Missing snapshot build configuration: ${build_config}" >&2
  exit 2
}

case "${uat_tag}" in
  uat-daily-build-*) release_tag="v${uat_tag#uat-daily-build-}" ;;
  daily-build-*) release_tag="v${uat_tag#daily-build-}" ;;
esac

[[ "${release_tag}" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::Could not derive a formal release tag from ${uat_tag}." >&2
  exit 2
}

token_for_org() {
  case "$1" in
    ai-workspace-infra) printf '%s' "${GH_TOKEN_INFRA:?GH_TOKEN_INFRA must be set}" ;;
    ai-workspace-services) printf '%s' "${GH_TOKEN_SERVICES:?GH_TOKEN_SERVICES must be set}" ;;
    *)
      echo "::error::No promotion token configured for organization: $1" >&2
      return 2
      ;;
  esac
}

gh_repo() {
  local repository="$1"
  shift
  GH_TOKEN="$(token_for_org "${repository%%/*}")" gh api "$@"
}

# A missing tag prints nothing; see read-ref-sha.sh for why `|| true` is not
# enough.
tag_sha() {
  local repository="$1" tag="$2"
  read_ref_sha gh_repo "${repository}" "repos/${repository}/git/ref/tags/${tag}" --jq '.object.sha'
}

create_tag() {
  local repository="$1" tag="$2" sha="$3"
  GH_TOKEN="$(token_for_org "${repository%%/*}")" gh api --method POST \
    "repos/${repository}/git/refs" \
    -f "ref=refs/tags/${tag}" \
    -f "sha=${sha}" >/dev/null
  echo "Created ${repository}:${tag} -> ${sha}"
}

mapfile -t repositories < <(
  jq -r --arg org "${promotion_organization}" \
    '.repositories[] | select(.repository | startswith($org + "/")) | .repository' "${build_config}"
)
[[ "${#repositories[@]}" -gt 0 ]] || {
  echo "::error::No ${promotion_organization} repositories are configured for production promotion." >&2
  exit 1
}

# A repository that must publish a production image but lives outside the
# promotion organization would be silently left untagged; refuse instead.
mapfile -t unpromotable < <(
  jq -r --arg org "${promotion_organization}" \
    '.repositories[]
     | select(.production_promotion == true and ((.repository | startswith($org + "/")) | not))
     | .repository' "${build_config}"
)
[[ "${#unpromotable[@]}" -eq 0 ]] || {
  echo "::error::production_promotion repositories outside ${promotion_organization} cannot be promoted: ${unpromotable[*]}" >&2
  exit 1
}

control_plane_repository="ai-workspace-infra/platform-ops-toolkit"

# Phase 1: verify everything before creating anything.
declare -A source_sha=()
declare -A release_exists=()
for repository in "${repositories[@]}"; do
  uat_sha="$(tag_sha "${repository}" "${uat_tag}")"
  [[ "${uat_sha}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "::error::UAT tag ${uat_tag} is missing from ${repository}; refusing PROD promotion." >&2
    exit 1
  }
  source_sha["${repository}"]="${uat_sha}"
  existing="$(tag_sha "${repository}" "${release_tag}")"
  if [[ -n "${existing}" ]]; then
    [[ "${existing}" == "${uat_sha}" ]] || {
      echo "::error::Refusing to move ${repository}:${release_tag}; it points to ${existing}, expected ${uat_sha}." >&2
      exit 1
    }
    release_exists["${repository}"]=1
  fi
done

# The control-plane repository is not part of the component build inventory,
# but PROD workflows must run from the same protected release tag.
source_sha["${control_plane_repository}"]="${control_plane_sha}"
existing="$(tag_sha "${control_plane_repository}" "${release_tag}")"
if [[ -n "${existing}" ]]; then
  [[ "${existing}" == "${control_plane_sha}" ]] || {
    echo "::error::Refusing to move ${control_plane_repository}:${release_tag}; it points to ${existing}, expected ${control_plane_sha}." >&2
    exit 1
  }
  release_exists["${control_plane_repository}"]=1
fi

# Phase 2: create the missing tags (all verified above).
for repository in "${repositories[@]}" "${control_plane_repository}"; do
  if [[ -n "${release_exists[${repository}]:-}" ]]; then
    echo "Verified ${repository}:${release_tag} -> ${source_sha[${repository}]}"
  else
    create_tag "${repository}" "${release_tag}" "${source_sha[${repository}]}"
  fi
done

printf 'release_tag=%s\n' "${release_tag}" >> "${output_file}"
echo "Promoted ${uat_tag} to ${release_tag} after successful UAT Hybrid validation."
