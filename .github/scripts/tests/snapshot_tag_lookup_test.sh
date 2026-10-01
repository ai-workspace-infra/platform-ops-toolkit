#!/usr/bin/env bash
# Tag lookups must treat GitHub's 404 body as "no such tag".
#
# `gh api` writes the error body to stdout and ignores --jq for it, so a
# missing tag prints {"message":"Not Found",...}. Daily 36847896719 read that
# JSON as an existing release tag and refused to "move" it. A tag exists only
# when `gh api` succeeds and returns a 40-hex SHA. Covered for each script:
#   tag missing                -> create (promotion) / keep the tag (resolver)
#   tag at the same commit     -> skip creation / keep the tag
#   tag at a different commit  -> refuse (promotion) / next revision (resolver)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
helper="${repo_root}/.github/scripts/snapshots/read-ref-sha.sh"
promote="${repo_root}/.github/scripts/snapshots/promote-uat-snapshot-tag.sh"
resolver="${repo_root}/.github/scripts/snapshots/resolve-snapshot-tag.sh"
build_config="${repo_root}/.github/daily-snapshot-builds.json"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
sha_for() { printf '%s' "$1" | sha1sum | cut -c1-40; }

# A `gh api` stand-in with GitHub's real error behaviour. Tags live in
# ${TAGS_DIR}/<owner>__<repo>@<tag>, branch heads in ${COMMITS_DIR}/<owner>__<repo>@<ref>.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
shift
method=GET; filter=''; endpoint=''; fields=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    -f) fields+=("$2"); shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
printf '%s %s\n' "${method}" "${endpoint}" >> "${GH_LOG}"
respond() {
  if [[ -n "${filter}" ]]; then jq -r "${filter}" <<<"$1"; else printf '%s\n' "$1"; fi
}
# Real gh: error body on stdout (no --jq applied), message on stderr, exit 1.
http_error() {
  printf '{"message":"%s","documentation_url":"https://docs.github.com/rest/git/refs","status":"%s"}\n' "$2" "$1"
  echo "gh: $2 (HTTP $1)" >&2
  exit 1
}
repository="${endpoint#repos/}"; repository="${repository%%/git/*}"; repository="${repository%%/commits/*}"
key="${repository//\//__}"
case "${method} ${endpoint}" in
  "GET repos/"*"/git/ref/tags/"*)
    tag="${endpoint##*/git/ref/tags/}"
    [[ -f "${TAGS_DIR}/${key}@${tag}" ]] || http_error 404 "Not Found"
    respond "{\"ref\":\"refs/tags/${tag}\",\"object\":{\"type\":\"commit\",\"sha\":\"$(cat "${TAGS_DIR}/${key}@${tag}")\"}}"
    ;;
  "GET repos/"*"/commits/"*)
    ref="${endpoint##*/commits/}"
    [[ -f "${COMMITS_DIR}/${key}@${ref}" ]] || http_error 422 "No commit found for SHA: ${ref}"
    respond "{\"sha\":\"$(cat "${COMMITS_DIR}/${key}@${ref}")\"}"
    ;;
  "POST repos/"*"/git/refs")
    ref=''; sha=''
    for field in "${fields[@]}"; do
      case "${field}" in ref=*) ref="${field#ref=}" ;; sha=*) sha="${field#sha=}" ;; esac
    done
    tag="${ref#refs/tags/}"
    [[ ! -f "${TAGS_DIR}/${key}@${tag}" ]] || http_error 422 "Reference already exists"
    printf '%s' "${sha}" > "${TAGS_DIR}/${key}@${tag}"
    printf 'CREATED %s %s\n' "${repository}" "${tag}" >> "${GH_LOG}"
    ;;
  *) echo "unexpected gh call: ${method} ${endpoint}" >&2; exit 1 ;;
esac
FAKE
chmod +x "${work}/bin/gh"

reset_store() {
  rm -rf "${work}/tags" "${work}/commits"
  mkdir -p "${work}/tags" "${work}/commits"
  : > "${work}/gh.log"
}
put_tag() { printf '%s' "$3" > "${work}/tags/${1//\//__}@$2"; }
tag_of() { cat "${work}/tags/${1//\//__}@$2"; }
gh_env=(PATH="${work}/bin:${PATH}" GH_LOG="${work}/gh.log" TAGS_DIR="${work}/tags" COMMITS_DIR="${work}/commits")

# --- read_ref_sha -------------------------------------------------------------
# shellcheck source=/dev/null
. "${helper}"
reset_store
put_tag acme/app v1 "$(sha_for one)"
lookup() { env "${gh_env[@]}" gh api "repos/acme/app/git/ref/tags/$1" --jq '.object.sha'; }
[[ "$(read_ref_sha lookup v1)" == "$(sha_for one)" ]] || fail "an existing tag must return its SHA"
[[ -z "$(read_ref_sha lookup missing)" ]] || fail "a 404 body must not be read as a SHA"
not_a_sha() { echo null; }
[[ -z "$(read_ref_sha not_a_sha)" ]] || fail "a successful non-SHA answer means no tag"
failed_with_sha() { sha_for two; return 1; }
[[ -z "$(read_ref_sha failed_with_sha)" ]] || fail "a failed call means no tag even if it printed a SHA"
# The exact shape that broke Daily 36847896719: the old `|| true` lookup.
old_lookup="$(lookup missing 2>/dev/null || true)"
[[ "${old_lookup}" == *'"Not Found"'* ]] || fail "the fake must reproduce gh's 404 body on stdout"

# --- promote-uat-snapshot-tag.sh ------------------------------------------------
uat_tag='daily-build-2026.10.01-r7'
release_tag='v2026.10.01-r7'
control_plane='ai-workspace-infra/platform-ops-toolkit'
control_plane_sha="$(sha_for control-plane)"
mapfile -t services < <(jq -r '.repositories[] | select(.repository | startswith("ai-workspace-services/")) | .repository' "${build_config}")
[[ "${#services[@]}" -gt 0 ]] || fail "the build config lists no services repositories"

seed_uat() {
  reset_store
  local repository
  for repository in "${services[@]}"; do put_tag "${repository}" "${uat_tag}" "$(sha_for "${repository}")"; done
}
run_promote() {
  : > "${work}/output"
  env "${gh_env[@]}" UAT_TAG="${uat_tag}" BUILD_CONFIG="${build_config}" CONTROL_PLANE_SHA="${control_plane_sha}" \
    GH_TOKEN_INFRA=infra GH_TOKEN_SERVICES=services GITHUB_OUTPUT="${work}/output" \
    bash "${promote}" > "${work}/promote.out" 2>&1
}

# Missing release tags -> created at the UAT commits.
seed_uat
run_promote || { cat "${work}/promote.out" >&2; fail "missing release tags must be created"; }
for repository in "${services[@]}"; do
  [[ "$(tag_of "${repository}" "${release_tag}")" == "$(sha_for "${repository}")" ]] \
    || fail "${repository}:${release_tag} must point at its UAT commit"
done
[[ "$(tag_of "${control_plane}" "${release_tag}")" == "${control_plane_sha}" ]] || fail "control-plane tag missing"
grep -Fxq "release_tag=${release_tag}" "${work}/output" || fail "release_tag output missing"

# Release tags already at the same commits -> verified, nothing created.
: > "${work}/gh.log"
run_promote || { cat "${work}/promote.out" >&2; fail "existing identical release tags must be accepted"; }
! grep -q '^CREATED\|^POST' "${work}/gh.log" || fail "an existing identical tag must not be recreated"
grep -Fq "Verified ai-workspace-services/accounts:${release_tag}" "${work}/promote.out" || fail "verification not reported"

# A release tag at a different commit -> refused before anything is created.
seed_uat
put_tag ai-workspace-services/portal "${release_tag}" "$(sha_for elsewhere)"
run_promote && fail "a release tag at another commit must not be moved"
grep -Fq "Refusing to move ai-workspace-services/portal:${release_tag}; it points to $(sha_for elsewhere)" "${work}/promote.out" \
  || fail "the refusal must name the conflicting commit"
! grep -q '^POST' "${work}/gh.log" || fail "the refusal must come before any tag is created"
[[ "$(tag_of ai-workspace-services/portal "${release_tag}")" == "$(sha_for elsewhere)" ]] || fail "the existing tag was moved"

# --- resolve-snapshot-tag.sh -----------------------------------------------------
resolver_repos=(ai-workspace-services/accounts ai-workspace-services/portal)
seed_heads() {
  reset_store
  local repository
  for repository in "${resolver_repos[@]}"; do
    printf '%s' "$(sha_for "head-${repository}")" > "${work}/commits/${repository//\//__}@main"
  done
}
run_resolver() {
  : > "${work}/output"
  env "${gh_env[@]}" GITHUB_WORKSPACE="${repo_root}" DEPLOY_ENV=uat SNAPSHOT_REF=main \
    SNAPSHOT_TAG=daily-build-2026.10.01 SNAPSHOT_REPOS="$(IFS=,; echo "${resolver_repos[*]}")" \
    SNAPSHOT_TOKEN_AI_WORKSPACE_INFRA=t SNAPSHOT_TOKEN_AI_WORKSPACE_LAB=t \
    SNAPSHOT_TOKEN_AI_WORKSPACE_SERVICES=t SNAPSHOT_TOKEN_AI_WORKSPACE_XSTREAM=t \
    GITHUB_OUTPUT="${work}/output" bash "${resolver}" > "${work}/resolve.out" 2>&1
}

# Tag missing everywhere -> keep the requested tag.
seed_heads
run_resolver || { cat "${work}/resolve.out" >&2; fail "the resolver must accept a missing tag"; }
grep -Fxq 'snapshot_tag=daily-build-2026.10.01' "${work}/output" || fail "a missing tag must be kept, not bumped"

# Tag already at the same commits -> keep it.
seed_heads
for repository in "${resolver_repos[@]}"; do put_tag "${repository}" daily-build-2026.10.01 "$(sha_for "head-${repository}")"; done
run_resolver || { cat "${work}/resolve.out" >&2; fail "the resolver must accept an identical tag"; }
grep -Fxq 'snapshot_tag=daily-build-2026.10.01' "${work}/output" || fail "an identical tag must be kept"

# Tag at a different commit -> move on to the next free revision.
seed_heads
put_tag ai-workspace-services/portal daily-build-2026.10.01 "$(sha_for elsewhere)"
run_resolver || { cat "${work}/resolve.out" >&2; fail "the resolver must pick a new revision on conflict"; }
grep -Fxq 'snapshot_tag=daily-build-2026.10.01-r1' "${work}/output" || fail "a conflicting tag must lead to -r1"

# A ref that cannot be resolved must stop, not pass a 404 body on as a SHA.
seed_heads
rm -f "${work}/commits/ai-workspace-services__portal@main"
run_resolver && fail "an unresolvable source ref must stop the resolver"
grep -Fq 'Cannot resolve main in ai-workspace-services/portal' "${work}/resolve.out" || fail "the resolver must name the unresolvable ref"

echo "snapshot_tag_lookup_test: PASS"
