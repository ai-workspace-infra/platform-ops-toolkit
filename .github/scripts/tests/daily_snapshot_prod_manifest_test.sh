#!/usr/bin/env bash
set -euo pipefail

# Production v* tags deliberately do not publish the daily/UAT-only
# release-manifest.json. A successful matching CI run must still unblock the
# production snapshot.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
waiter="${repo_root}/.github/scripts/snapshots/wait-daily-snapshot-builds.sh"
prod_dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-prod-combined.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "api "*)
    printf 'test-sha\n'
    ;;
  "run list")
    printf '%s\n' '[{"databaseId":42,"event":"push","status":"completed","headBranch":"v2026.08.28-r3","headSha":"test-sha"}]'
    ;;
  "run view")
    printf '%s\n' '{"status":"completed","conclusion":"success"}'
    ;;
  "release "*)
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
  BUILD_TIMEOUT_SECONDS=1 \
  BUILD_POLL_SECONDS=0 \
  bash "${waiter}"

jq -se '
  [ .[] | select(.repository == "ai-workspace-services/accounts" and .status == "build_succeeded") ]
  | length == 1
' "${status_file}" >/dev/null

# A PROD tag is also the GitHub OIDC identity presented to Vault. Dispatching
# either orchestrator from main would change that claim to refs/heads/main and
# bypass the intended narrow refs/tags/v* Vault role binding.
[[ "$(grep -Fxc -- '--ref "${release_tag}" \\' "${prod_dispatcher}")" -eq 2 ]]
! grep -Fq -- '--ref main' "${prod_dispatcher}"

echo "daily_snapshot_prod_manifest_test: PASS"
