#!/usr/bin/env bash
set -euo pipefail

# The xray-exporter release is a binary release, not a service release
# manifest. Verify the snapshot waiter requires its linux/amd64 asset.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
waiter="${repo_root}/.github/scripts/snapshots/wait-daily-snapshot-builds.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  api)
    printf 'xray-test-sha\n'
    ;;
  run)
    case "$2" in
      list)
        printf '%s\n' '[{"databaseId":77,"event":"push","status":"completed","headBranch":"daily-build-test","headSha":"xray-test-sha"}]'
        ;;
      view)
        printf '%s\n' '{"status":"completed","conclusion":"success"}'
        ;;
    esac
    ;;
  release)
    if [[ " $* " == *" --json assets "* ]]; then
      printf '%s\n' '["xray-exporter-linux-amd64","xray-exporter-linux-arm64"]'
    else
      printf '%s\n' 'https://github.example/xray-release'
    fi
    ;;
esac
EOF
chmod +x "${workdir}/gh"

status_file="${workdir}/status.jsonl"
PATH="${workdir}:${PATH}" \
  GH_TOKEN=test \
  SNAPSHOT_TAG=daily-build-test \
  SNAPSHOT_ORGANIZATION=ai-workspace-xstream \
  SNAPSHOT_REPOS=ai-workspace-xstream/xray-exporter \
  SNAPSHOT_STATUS_FILE="${status_file}" \
  BUILD_TIMEOUT_SECONDS=10 \
  BUILD_POLL_SECONDS=0 \
  bash "${waiter}"

jq -se '[.[] | select(.repository == "ai-workspace-xstream/xray-exporter" and .status == "build_succeeded")] | length == 1' \
  "${status_file}" >/dev/null

echo "daily_snapshot_xray_release_test: PASS"
