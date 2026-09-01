#!/usr/bin/env bash
set -euo pipefail

# The source tag may contain an older workflow definition. Production Cloud
# Run images must therefore be dispatched from main with the immutable tag as
# source_ref, and the snapshot script must wait for those runs before deploy.

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
    if [[ " $* " == *"installation/repositories"* ]]; then
      printf '%s\n' \
        'ai-workspace-services/accounts' \
        'ai-workspace-services/billing-service' \
        'ai-workspace-services/content-service'
    elif [[ " $* " == *"/git/ref/tags/"* ]]; then
      exit 1
    elif [[ " $* " == *"/commits/"* ]]; then
      printf 'test-sha\n'
    elif [[ " $* " == *" --jq .default_branch "* ]]; then
      printf 'main\n'
    fi
    ;;
  workflow)
    printf 'https://github.com/%s/actions/runs/987654321\n' "$(printf '%s' "$*" | sed -n 's/.*--repo \([^ ]*\).*/\1/p')"
    ;;
  run)
    case "$2" in
      list)
        printf '%s\n' '[{"databaseId":42,"event":"push","status":"completed","conclusion":"success","headBranch":"v2026.09.01-r99","headSha":"test-sha"}]'
        ;;
      watch)
        exit 0
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
DEPLOY_ENV=prod \
SNAPSHOT_TAG=v2026.09.01-r99 \
SNAPSHOT_REF=uat-daily-build-2026.09.01-r1 \
SNAPSHOT_ORGS=ai-workspace-services \
SNAPSHOT_REPOS=ai-workspace-services/accounts,ai-workspace-services/billing-service,ai-workspace-services/content-service \
SNAPSHOT_STATUS_FILE="${status_file}" \
SNAPSHOT_VERIFY_INSTALLATION_ACCESS=true \
BUILD_TIMEOUT_SECONDS=1 \
BUILD_POLL_SECONDS=0 \
bash "${snapshot_script}"

for repo in accounts billing-service content-service; do
  grep -Fq "workflow run ci-pipeline.yml --repo ai-workspace-services/${repo} --ref main" "${workdir}/gh.log"
  grep -Fq "source_ref=v2026.09.01-r99" "${workdir}/gh.log"
  grep -Fq "image_tag=v2026.09.01-r99" "${workdir}/gh.log"
done

[[ "$(jq -se '[.[] | select(.status == "build_succeeded")] | length' "${status_file}")" -eq 3 ]]

echo "daily_snapshot_prod_image_promotion_test: PASS"
