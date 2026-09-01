#!/usr/bin/env bash
set -euo pipefail

# A second tag attempt can race GitHub's ref visibility after the first create.
# A 422 Reference already exists is successful when the immutable ref has the
# expected SHA; the build dispatch must still happen.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tag_script="${repo_root}/docs/tasks/tag-ai-workspace-mains.sh"
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
      *"default_branch"*)
        printf 'main\n'
        ;;
      *"/commits/"*)
        printf 'expected-sha\n'
        ;;
      *"/git/ref/tags/race-tag"*)
        if [[ ! -e "${TAG_SEEN}" ]]; then
          : >"${TAG_SEEN}"
          exit 1
        fi
        printf '%s\n' '{"object":{"sha":"expected-sha"}}'
        ;;
      *"/git/refs"*)
        printf '%s\n' 'HTTP/2.0 422 Unprocessable Entity'
        printf '\n'
        printf '%s\n' '{"message":"Reference already exists"}'
        exit 1
        ;;
    esac
    ;;
  workflow)
    exit 0
    ;;
esac
EOF
chmod +x "${workdir}/gh"

GH_LOG="${workdir}/gh.log" \
TAG_SEEN="${workdir}/tag-seen" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test \
DEPLOY_ENV=uat \
SNAPSHOT_ORGS=ai-workspace-lab \
SNAPSHOT_STATUS_FILE="${workdir}/status.jsonl" \
  bash "${tag_script}" --tag race-tag --ref main --org ai-workspace-lab --repo ai-workspace-lab/xworkmate-bridge --apply --build

grep -Fq 'workflow run pipeline.yml --repo ai-workspace-lab/xworkmate-bridge --ref race-tag' "${workdir}/gh.log"
jq -se '
  ([.[] | select(.repository == "ai-workspace-lab/xworkmate-bridge" and .status == "unchanged")] | length == 1)
  and ([.[] | select(.repository == "ai-workspace-lab/xworkmate-bridge" and .status == "dispatched")] | length == 1)
' \
  "${workdir}/status.jsonl" >/dev/null

echo "daily_snapshot_tag_race_test: PASS"
