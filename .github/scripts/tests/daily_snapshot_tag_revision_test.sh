#!/usr/bin/env bash
set -euo pipefail

# A stale immutable tag must advance to the next revision before the snapshot
# waiter looks for a CI run. This protects scheduled snapshots from waiting on
# a failed build attached to an older commit.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
snapshot_script="${repo_root}/.github/scripts/snapshots/tag-daily-main-snapshot.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${GH_LOG}"
printf '\n' >>"${GH_LOG}"

case "$1" in
  auth)
    exit 0
    ;;
  api)
    case "$*" in
      *"/commits/"*)
        printf 'new-sha\n'
        ;;
      *"/git/ref/tags/uat-daily-build-2026.08.19-r1"*)
        printf '%s\n' '{"object":{"sha":"old-sha"}}'
        ;;
      *"/git/ref/tags/uat-daily-build-2026.08.19-r2"*)
        exit 1
        ;;
      *"/git/refs"*)
        exit 0
        ;;
      *"default_branch"*)
        printf 'main\n'
        ;;
    esac
    ;;
  workflow)
    exit 0
    ;;
  release)
    if [[ "$*" == *"--json assets"* ]]; then
      printf '%s\n' '["release-manifest.json"]'
    else
      printf 'https://github.com/ai-workspace-services/portal/releases/tag/uat-daily-build-2026.08.19-r2\n'
    fi
    ;;
  run)
    case "$2" in
      list)
        printf '%s\n' '[{"databaseId":77,"event":"push","status":"completed","headBranch":"uat-daily-build-2026.08.19-r2","headSha":"new-sha"}]'
        ;;
      view)
        printf '%s\n' '{"status":"completed","conclusion":"success"}'
        ;;
    esac
    ;;
esac
EOF
chmod +x "${workdir}/gh"

status_file="${workdir}/status.jsonl"
GH_LOG="${workdir}/gh.log" \
PATH="${workdir}:${PATH}" \
GITHUB_WORKSPACE="${repo_root}" \
GH_TOKEN=test \
DEPLOY_ENV=uat \
SNAPSHOT_TAG=uat-daily-build-2026.08.19-r1 \
SNAPSHOT_ORGS=ai-workspace-services \
SNAPSHOT_REPOS=ai-workspace-services/portal \
SNAPSHOT_STATUS_FILE="${status_file}" \
  BUILD_TIMEOUT_SECONDS=5 \
BUILD_POLL_SECONDS=0 \
bash "${snapshot_script}"

grep -Fq 'refs/tags/uat-daily-build-2026.08.19-r2' "${workdir}/gh.log"
jq -se '[.[] | select(.repository == "ai-workspace-services/portal" and .tag == "uat-daily-build-2026.08.19-r2" and .status == "build_succeeded")] | length == 1' \
  "${status_file}" >/dev/null

echo "daily_snapshot_tag_revision_test: PASS"
