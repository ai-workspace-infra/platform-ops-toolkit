#!/usr/bin/env bash
set -euo pipefail

# Promote the exact immutable UAT component tags to a formal v* release tag.
# This script is called only after the UAT Hybrid workflow has completed
# successfully. Existing release tags are never moved.

uat_tag="${UAT_TAG:?UAT_TAG must be set}"
build_config="${BUILD_CONFIG:?BUILD_CONFIG must be set}"
control_plane_sha="${CONTROL_PLANE_SHA:?CONTROL_PLANE_SHA must be set}"
output_file="${GITHUB_OUTPUT:-/dev/stdout}"

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

tag_sha() {
  local repository="$1" tag="$2"
  gh_repo "${repository}" "repos/${repository}/git/ref/tags/${tag}" --jq '.object.sha' 2>/dev/null || true
}

create_or_verify_tag() {
  local repository="$1" tag="$2" sha="$3" existing
  existing="$(tag_sha "${repository}" "${tag}")"
  if [[ -n "${existing}" ]]; then
    [[ "${existing}" == "${sha}" ]] || {
      echo "::error::Refusing to move ${repository}:${tag}; it points to ${existing}, expected ${sha}." >&2
      return 1
    }
    echo "Verified ${repository}:${tag} -> ${sha}"
    return 0
  fi

  GH_TOKEN="$(token_for_org "${repository%%/*}")" gh api --method POST \
    "repos/${repository}/git/refs" \
    -f "ref=refs/tags/${tag}" \
    -f "sha=${sha}" >/dev/null
  echo "Created ${repository}:${tag} -> ${sha}"
}

mapfile -t repositories < <(
  jq -r '.repositories[] | select(.production_promotion == true) | .repository' "${build_config}"
)
[[ "${#repositories[@]}" -gt 0 ]] || {
  echo "::error::No production promotion repositories are configured." >&2
  exit 1
}

for repository in "${repositories[@]}"; do
  uat_sha="$(tag_sha "${repository}" "${uat_tag}")"
  [[ "${uat_sha}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "::error::UAT tag ${uat_tag} is missing from ${repository}; refusing PROD promotion." >&2
    exit 1
  }
  create_or_verify_tag "${repository}" "${release_tag}" "${uat_sha}"
done

# The control-plane repository is not part of the component build inventory,
# but PROD workflows must run from the same protected release tag.
control_plane_repository="ai-workspace-infra/platform-ops-toolkit"
create_or_verify_tag "${control_plane_repository}" "${release_tag}" "${control_plane_sha}"

printf 'release_tag=%s\n' "${release_tag}" >> "${output_file}"
echo "Promoted ${uat_tag} to ${release_tag} after successful UAT Hybrid validation."
