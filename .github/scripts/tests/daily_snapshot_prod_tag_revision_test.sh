#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
resolver="${repo_root}/.github/scripts/snapshots/resolve-snapshot-tag.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *"/commits/"*)
    printf 'new-sha\n'
    ;;
  *"/git/ref/tags/v2026.09.01-r1"*)
    printf '%s\n' '{"object":{"sha":"old-sha"}}'
    ;;
  *"/git/ref/tags/v2026.09.01-r2"*)
    if [[ "${EXPECT_R4:-false}" == true ]]; then
      printf '%s\n' '{"object":{"sha":"old-sha"}}'
    else
      exit 1
    fi
    ;;
  *"/git/ref/tags/v2026.09.01-r3"*)
    if [[ "${EXPECT_R4:-false}" == true ]]; then
      printf '%s\n' '{"object":{"sha":"old-sha"}}'
    else
      exit 1
    fi
    ;;
  *"/git/ref/tags/v2026.09.01-r4"*)
    exit 1
    ;;
  *"/git/ref/tags/v2026.09.01"*)
    printf '%s\n' '{"object":{"sha":"old-sha"}}'
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
