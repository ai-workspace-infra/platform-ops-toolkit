#!/usr/bin/env bash
set -euo pipefail

# Exercises the snapshot waiter without GitHub access.  The first repository
# intentionally never gets a run; the second is already complete.  It proves
# a per-repository timeout cannot hide a later successful build and that the
# matrix organization filter excludes cross-organization repositories.

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
        if [[ " $* " == *" ai-workspace-services/portal "* ]]; then
          printf '%s\n' '[{"databaseId":42,"event":"push","status":"completed","headBranch":"uat-daily-build-test","headSha":"test-sha"}]'
        else
          printf '[]\n'
        fi
        ;;
      view)
        if [[ " $* " == *" --json status,conclusion "* ]]; then
          printf '%s\n' '{"status":"completed","conclusion":"success"}'
        else
          printf 'https://github.example/release\n'
        fi
        ;;
    esac
    ;;
  release)
    if [[ " $* " == *" --json assets "* ]]; then
      printf '%s\n' '["release-manifest.json"]'
    else
      printf 'https://github.example/release\n'
    fi
    ;;
esac
EOF
chmod +x "${workdir}/gh"

status_file="${workdir}/status.jsonl"
set +e
PATH="${workdir}:${PATH}" \
  GH_TOKEN=test \
  SNAPSHOT_TAG=uat-daily-build-test \
  SNAPSHOT_ORGANIZATION=ai-workspace-services \
  SNAPSHOT_REPOS=ai-workspace-services/accounts,ai-workspace-lab/xworkmate-bridge,ai-workspace-services/portal \
  SNAPSHOT_STATUS_FILE="${status_file}" \
  BUILD_TIMEOUT_SECONDS=1 \
  BUILD_POLL_SECONDS=0 \
  bash "${waiter}"
exit_code=$?
set -e

[[ "${exit_code}" -eq 1 ]] || {
  echo "expected timeout failure from accounts, got ${exit_code}" >&2
  exit 1
}
jq -se '
  [ .[] | select(.repository == "ai-workspace-services/accounts" and .status == "build_timeout") ]
  | length == 1
' "${status_file}" >/dev/null
jq -se '
  [ .[] | select(.repository == "ai-workspace-services/portal" and .status == "build_succeeded") ]
  | length == 1
' "${status_file}" >/dev/null
if grep -q 'xworkmate-bridge' "${status_file}"; then
  echo "cross-organization repository was not filtered" >&2
  exit 1
fi

echo "daily_snapshot_waiter_scope_test: PASS"
