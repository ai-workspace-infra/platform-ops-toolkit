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
    printf '%s\n' '[{"databaseId":42,"event":"workflow_dispatch","status":"completed","headBranch":"main","headSha":"test-sha"}]'
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
  BUILD_TIMEOUT_SECONDS=5 \
  BUILD_POLL_SECONDS=0 \
  bash "${waiter}"

jq -se '
  [ .[] | select(.repository == "ai-workspace-services/accounts" and .status == "build_succeeded") ]
  | length == 1
' "${status_file}" >/dev/null

# A PROD tag is also the GitHub OIDC identity presented to Vault. Dispatching
# either orchestrator from main would change that claim to refs/heads/main and
# bypass the intended narrow refs/tags/v* Vault role binding.
[[ "$(grep -Fxc -- '--ref "${release_tag}" "$@"' "${prod_dispatcher}")" -eq 0 ]]
! grep -Fq -- '--ref main' "${prod_dispatcher}"
grep -Fq -- 'git/ref/tags/${release_tag}' "${prod_dispatcher}"
grep -Fq -- 'resolved to ref' "${prod_dispatcher}"

# The routine production snapshot must use 'upgrade' instead of data migration
# and never implicitly require the separate PROD accounts-migration contract.
grep -Fq -- 'serverless_op="upgrade"' "${prod_dispatcher}"
grep -Fq -- '-f "operation=${serverless_op}" -f target_domains=web-saas' "${prod_dispatcher}"
grep -Fq -- '-f target_domain_base=svc.plus -f dns_mode=none' "${prod_dispatcher}"
if grep -Fq -- 'dns_mode=prod-cutover' "${prod_dispatcher}"; then
  echo 'Daily PROD promotion must not cut over canonical DNS without a separate approval' >&2
  exit 1
fi

# PROD child runs are awaited with the shared waiter (job token, bounded
# transient-error budget, explicit success), never `gh run watch`, which exits
# on the first API error and would read status with the expiring App token.
if grep -Fq 'gh run watch' "${prod_dispatcher}"; then
  echo 'PROD dispatch must not wait with gh run watch.' >&2
  exit 1
fi
grep -Fq 'wait-for-workflow-run.sh' "${prod_dispatcher}"
for label in 'PROD Serverless' 'PROD AWS Selfhost' 'PROD Akamai Selfhost'; do
  grep -Eq "^wait_for_prod_run \"[^\"]+\" \"${label}\"$" "${prod_dispatcher}" || {
    echo "PROD dispatch must wait for ${label} with the shared waiter." >&2
    exit 1
  }
done

echo "daily_snapshot_prod_manifest_test: PASS"
