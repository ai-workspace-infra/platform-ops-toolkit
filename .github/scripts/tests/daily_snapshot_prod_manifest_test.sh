#!/usr/bin/env bash
set -euo pipefail

# Production v* tags deliberately do not publish the daily/UAT-only
# release-manifest.json. A successful matching CI run must still unblock the
# production snapshot.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
waiter="${repo_root}/.github/scripts/snapshots/wait-daily-snapshot-builds.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  api)
    printf 'test-sha\n'
    ;;
  run)
    case "$2" in
      list)
        printf '%s\n' '[{"databaseId":42,"event":"push","status":"completed","headBranch":"v2026.08.28-r3","headSha":"test-sha"}]'
        ;;
      view)
        printf '%s\n' '{"status":"completed","conclusion":"success"}'
        ;;
    esac
    ;;
  release)
    echo "release lookup must not run for a production v* snapshot" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${workdir}/gh"

status_file="${workdir}/status.jsonl"
PATH="${workdir}:${PATH}" \
  GH_TOKEN=test \
  SNAPSHOT_TAG=v2026.08.28-r3 \
  SNAPSHOT_ORGANIZATION=ai-workspace-services \
  SNAPSHOT_REPOS=ai-workspace-services/accounts \
  SNAPSHOT_STATUS_FILE="${status_file}" \
  BUILD_TIMEOUT_SECONDS=5 \
  BUILD_POLL_SECONDS=0 \
  bash "${waiter}"

jq -se '
  [ .[] | select(.repository == "ai-workspace-services/accounts" and .status == "build_succeeded") ]
  | length == 1
' "${status_file}" >/dev/null

echo "daily_snapshot_prod_manifest_test: PASS"
