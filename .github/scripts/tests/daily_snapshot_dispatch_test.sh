#!/usr/bin/env bash
set -euo pipefail

# Validates the scheduled lab matrix path without GitHub access: only the
# configured bridge repository is tagged, and its non-tag-triggered build is
# dispatched on the immutable snapshot tag with the expected inputs.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
snapshot_script="${repo_root}/.github/scripts/tag-daily-main-snapshot.sh"
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
    if [[ " $* " == *"/git/ref/tags/"* ]]; then
      exit 1
    elif [[ " $* " == *"/commits/"* ]]; then
      printf 'test-sha\n'
    elif [[ " $* " == *" --jq .default_branch "* ]]; then
      printf 'main\n'
    fi
    ;;
  workflow)
    exit 0
    ;;
  run)
    case "$2" in
      list)
        printf '%s\n' '[{"databaseId":42,"event":"workflow_dispatch","status":"completed","headBranch":"uat-daily-build-test","headSha":"test-sha"}]'
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
SNAPSHOT_TAG=uat-daily-build-test \
SNAPSHOT_ORGS=ai-workspace-lab \
SNAPSHOT_STATUS_FILE="${status_file}" \
BUILD_TIMEOUT_SECONDS=1 \
BUILD_POLL_SECONDS=0 \
bash "${snapshot_script}"

grep -Fq 'workflow run pipeline.yml --repo ai-workspace-lab/xworkmate-bridge --ref uat-daily-build-test -f environment=uat -f run_apply=false' "${workdir}/gh.log"
if grep -Eq 'ai-workspace-lab/(qmd|xworkmate-app|xworkspace-console)' "${workdir}/gh.log"; then
  echo "scheduled snapshot touched an unconfigured lab repository" >&2
  exit 1
fi
jq -se '[ .[] | select(.repository == "ai-workspace-lab/xworkmate-bridge" and .status == "build_succeeded") ] | length == 1' \
  "${status_file}" >/dev/null

echo "daily_snapshot_dispatch_test: PASS"
