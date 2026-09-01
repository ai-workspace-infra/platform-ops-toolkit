#!/usr/bin/env bash
set -euo pipefail

# A missing repository in the installation token scope must stop the matrix
# before the first tag is written. This protects the immutable snapshot from
# becoming partially populated across repositories.
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
      printf '%s\n' 'ai-workspace-services/accounts'
      exit 0
    fi
    ;;
esac
EOF
chmod +x "${workdir}/gh"

if GH_LOG="${workdir}/gh.log" \
  PATH="${workdir}:${PATH}" \
  GITHUB_WORKSPACE="${repo_root}" \
  GH_TOKEN=test \
  DEPLOY_ENV=prod \
  SNAPSHOT_TAG=v2026.09.01-r10 \
  SNAPSHOT_ORGS=ai-workspace-services \
  SNAPSHOT_REPOS=ai-workspace-services/accounts,ai-workspace-services/billing-service \
  SNAPSHOT_VERIFY_INSTALLATION_ACCESS=true \
  SNAPSHOT_STATUS_FILE="${workdir}/status.jsonl" \
  bash "${snapshot_script}" >"${workdir}/stdout" 2>"${workdir}/stderr"; then
  echo "snapshot unexpectedly passed with billing-service absent from installation scope" >&2
  exit 1
fi

grep -Fq 'ai-workspace-services/billing-service' "${workdir}/stderr"
if grep -Fq 'git/refs' "${workdir}/gh.log"; then
  echo "snapshot wrote a tag before installation access preflight failed" >&2
  exit 1
fi

echo "daily_snapshot_installation_access_test: PASS"
