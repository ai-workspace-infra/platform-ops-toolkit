#!/usr/bin/env bash
set -euo pipefail

# Explicit repository filters may narrow a snapshot, but cannot bypass the
# environment eligibility declared in the canonical inventory. In particular,
# the UAT/SIT xray exporter must never receive a production release tag.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
snapshot_script="${repo_root}/.github/scripts/snapshots/tag-daily-main-snapshot.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${GH_LOG}"
printf '\n' >>"${GH_LOG}"
EOF
chmod +x "${workdir}/gh"

GH_LOG="${workdir}/gh.log" \
PATH="${workdir}:${PATH}" \
  GITHUB_WORKSPACE="${repo_root}" \
  GH_TOKEN=test \
  DEPLOY_ENV=prod \
  SNAPSHOT_TAG=v2026.08.15.3 \
  SNAPSHOT_ORGS=ai-workspace-xstream \
  SNAPSHOT_REPOS=ai-workspace-xstream/xray-exporter \
  SNAPSHOT_STATUS_FILE="${workdir}/status.jsonl" \
  bash "${snapshot_script}"

[[ ! -s "${workdir}/gh.log" ]] || {
  echo "production snapshot attempted to operate on the UAT/SIT-only exporter" >&2
  cat "${workdir}/gh.log" >&2
  exit 1
}

echo "daily_snapshot_environment_scope_test: PASS"
