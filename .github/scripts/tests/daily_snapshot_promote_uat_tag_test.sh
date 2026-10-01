#!/usr/bin/env bash
set -euo pipefail

# UAT -> PROD promotion must tag every repository the PROD orchestrators check
# out at the release tag (portal and frontend-router included), must be
# preflight all inputs before mutation, and never move an existing release tag.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
promote="${repo_root}/.github/scripts/snapshots/promote-uat-snapshot-tag.sh"
build_config="${repo_root}/.github/daily-snapshot-builds.json"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

uat_tag='daily-build-2026.09.30-r10'
release_tag='v2026.09.30-r10'
control_plane_sha="$(printf 'c%.0s' {1..40})"
tags_dir="${workdir}/tags"

# Fake GitHub tag store: one file per repository/tag holding the target SHA.
cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || exit 1
shift
method=GET
while [[ "$1" == --method ]]; do method="$2"; shift 2; done
endpoint="$1"; shift
if [[ "${method}" == POST ]]; then
  repository="${endpoint#repos/}"; repository="${repository%/git/refs}"
  [[ "${repository}" != "${FAIL_POST_REPOSITORY:-}" ]] || { echo 'Simulated GitHub API failure' >&2; exit 1; }
  ref=''; sha=''
  while [[ $# -gt 0 ]]; do
    case "$2" in
      ref=*) ref="${2#ref=}" ;;
      sha=*) sha="${2#sha=}" ;;
    esac
    shift 2
  done
  file="${TAGS_DIR}/${repository//\//__}@${ref#refs/tags/}"
  [[ ! -e "${file}" ]] || { echo 'Reference already exists' >&2; exit 1; }
  printf '%s' "${sha}" > "${file}"
  printf 'POST %s %s\n' "${repository}" "${ref}" >> "${GH_LOG}"
  exit 0
fi
repository="${endpoint#repos/}"; repository="${repository%%/git/ref/tags/*}"
tag="${endpoint##*/git/ref/tags/}"
file="${TAGS_DIR}/${repository//\//__}@${tag}"
if [[ ! -e "${file}" ]]; then
  # Real gh prints the 404 body to stdout, without applying --jq.
  echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/git/refs#get-a-reference","status":"404"}'
  exit 1
fi
cat "${file}"
EOF
chmod +x "${workdir}/gh"

sha_for() { printf '%s' "$1" | sha1sum | cut -c1-40; }

seed_uat_tags() {
  local skip="${1:-}" repository
  rm -rf "${tags_dir}"; mkdir -p "${tags_dir}"; : > "${workdir}/gh.log"
  while read -r repository; do
    [[ "${repository}" == "${skip}" ]] && continue
    sha_for "${repository}" > "${tags_dir}/${repository//\//__}@${uat_tag}"
  done < <(jq -r '.repositories[] | select(.repository | startswith("ai-workspace-services/")) | .repository' "${build_config}")
}

run_promote() {
  local config="${1:-${build_config}}"
  GH_LOG="${workdir}/gh.log" TAGS_DIR="${tags_dir}" PATH="${workdir}:${PATH}" \
    UAT_TAG="${uat_tag}" BUILD_CONFIG="${config}" CONTROL_PLANE_SHA="${control_plane_sha}" \
    GH_TOKEN_INFRA=infra-token GH_TOKEN_SERVICES=services-token \
    GITHUB_OUTPUT="${workdir}/output" \
    bash "${promote}"
}

tag_file() { printf '%s/%s@%s' "${tags_dir}" "${1//\//__}" "$2"; }

# 1. Happy path: every services repository (portal/frontend-router too) and the
#    control plane are tagged at the exact UAT commit.
seed_uat_tags
: > "${workdir}/output"
run_promote >/dev/null
for repository in accounts billing-service content-service portal edge-gateway frontend-router postgresql.svc.plus; do
  file="$(tag_file "ai-workspace-services/${repository}" "${release_tag}")"
  [[ -e "${file}" ]] || { echo "Missing release tag for ${repository}" >&2; exit 1; }
  [[ "$(cat "${file}")" == "$(sha_for "ai-workspace-services/${repository}")" ]] || {
    echo "Release tag for ${repository} does not point at the UAT commit" >&2; exit 1; }
done
[[ "$(cat "$(tag_file ai-workspace-infra/platform-ops-toolkit "${release_tag}")")" == "${control_plane_sha}" ]]
grep -Fxq "release_tag=${release_tag}" "${workdir}/output"

# 2. Idempotent rerun verifies instead of failing or creating duplicates.
: > "${workdir}/gh.log"
rerun_output="$(run_promote)"
grep -Fq 'Verified ai-workspace-services/portal' <<<"${rerun_output}"
[[ ! -s "${workdir}/gh.log" ]] || { echo 'Rerun must not create tags' >&2; exit 1; }

# 3. A missing UAT tag fails closed and creates nothing (no partial release).
seed_uat_tags ai-workspace-services/frontend-router
if run_promote >/dev/null 2>"${workdir}/err"; then
  echo 'Promotion must fail when a UAT tag is missing' >&2; exit 1
fi
grep -Fq 'frontend-router' "${workdir}/err"
[[ ! -s "${workdir}/gh.log" ]] || { echo 'Failed promotion must not create any tag' >&2; cat "${workdir}/gh.log" >&2; exit 1; }

# 4. An existing release tag that points elsewhere is never moved, and nothing
#    else is created.
seed_uat_tags
printf '%s' "$(printf 'd%.0s' {1..40})" > "$(tag_file ai-workspace-services/portal "${release_tag}")"
if run_promote >/dev/null 2>"${workdir}/err"; then
  echo 'Promotion must refuse to move an existing release tag' >&2; exit 1
fi
grep -Fq 'Refusing to move ai-workspace-services/portal' "${workdir}/err"
[[ ! -s "${workdir}/gh.log" ]] || { echo 'Refusal must happen before any tag is created' >&2; exit 1; }

# 5. A production_promotion repository outside the promotion organization must
#    not be silently skipped.
seed_uat_tags
jq '.repositories += [{"repository":"ai-workspace-lab/example","production_promotion":true}]' "${build_config}" > "${workdir}/builds.json"
if run_promote "${workdir}/builds.json" >/dev/null 2>"${workdir}/err"; then
  echo 'Promotion must reject production_promotion repositories it cannot tag' >&2; exit 1
fi
grep -Fq 'ai-workspace-lab/example' "${workdir}/err"

# 6. Cross-repository writes are not atomic. A write failure must stop before
# publishing the successful release output; retry completes missing refs only.
seed_uat_tags
: > "${workdir}/output"
if FAIL_POST_REPOSITORY=ai-workspace-services/frontend-router run_promote > /dev/null 2>"${workdir}/err"; then
  echo 'Promotion must stop on tag creation API failure' >&2; exit 1
fi
[[ ! -s "${workdir}/output" ]]
[[ -s "${workdir}/gh.log" ]]
[[ ! -e "$(tag_file ai-workspace-infra/platform-ops-toolkit "${release_tag}")" ]]
run_promote >/dev/null
grep -Fxq "release_tag=${release_tag}" "${workdir}/output"

echo "daily_snapshot_promote_uat_tag_test: PASS"
