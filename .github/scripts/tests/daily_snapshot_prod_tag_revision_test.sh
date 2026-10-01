#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
resolver="${repo_root}/.github/scripts/snapshots/resolve-snapshot-tag.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Answer like `gh api`: apply --jq to a success body; on 404 print GitHub's
# error body to stdout (without --jq) and exit 1.
filter=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == --jq ]] && filter="${args[i + 1]}"
done
old_sha="$(printf 'a%.0s' {1..40})"
new_sha="$(printf 'b%.0s' {1..40})"
found() { if [[ -n "${filter}" ]]; then jq -r "${filter}" <<<"$1"; else printf '%s\n' "$1"; fi; }
missing() {
  printf '%s\n' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/git/refs#get-a-reference","status":"404"}'
  exit 1
}
tag_at_old() { found "{\"object\":{\"type\":\"commit\",\"sha\":\"${old_sha}\"}}"; }

case "$*" in
  *"/commits/"*)
    found "{\"sha\":\"${new_sha}\"}"
    ;;
  *"/git/ref/tags/v2026.09.01-r1"*)
    tag_at_old
    ;;
  *"/git/ref/tags/v2026.09.01-r2"*|*"/git/ref/tags/v2026.09.01-r3"*)
    if [[ "${EXPECT_R4:-false}" == true ]]; then tag_at_old; else missing; fi
    ;;
  *"/git/ref/tags/v2026.09.01-r4"*)
    missing
    ;;
  *"/git/ref/tags/v2026.09.01"*)
    tag_at_old
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${workdir}/gh"

common_env=(
  PATH="${workdir}:${PATH}"
  GITHUB_WORKSPACE="${repo_root}"
  DEPLOY_ENV=prod
  SNAPSHOT_SOURCE_REF=uat-daily-build-2026.09.01-r1
  SNAPSHOT_REF=uat-daily-build-2026.09.01-r1
  SNAPSHOT_REPOS=ai-workspace-services/accounts,ai-workspace-services/portal
  SNAPSHOT_TOKEN_AI_WORKSPACE_INFRA=test
  SNAPSHOT_TOKEN_AI_WORKSPACE_LAB=test
  SNAPSHOT_TOKEN_AI_WORKSPACE_SERVICES=test
  SNAPSHOT_TOKEN_AI_WORKSPACE_XSTREAM=test
)

first_output="${workdir}/first-output"
env "${common_env[@]}" SNAPSHOT_TAG=v2026.09.01 GITHUB_OUTPUT="${first_output}" \
  bash "${resolver}"
grep -Fqx 'snapshot_tag=v2026.09.01-r2' "${first_output}"

second_output="${workdir}/second-output"
env "${common_env[@]}" SNAPSHOT_TAG=v2026.09.01-r2 EXPECT_R4=true GITHUB_OUTPUT="${second_output}" \
  bash "${resolver}"
grep -Fqx 'snapshot_tag=v2026.09.01-r4' "${second_output}"

echo "daily_snapshot_prod_tag_revision_test: PASS"
