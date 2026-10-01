#!/usr/bin/env bash
# Read-only provenance gate shared by Daily dispatch and PROD preflight.
set -euo pipefail
manifest_file="${1:?promotion manifest file is required}"
release_tag="${2:?release tag is required}"
snapshot_tag="${3:-}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${RUN_REPOSITORY:?RUN_REPOSITORY is required}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
run_id="$(jq -er '.uat_run_id | tostring | select(test("^[1-9][0-9]*$"))' "${manifest_file}")" || {
  echo '::error::Promotion manifest must name its accepted UAT run.' >&2
  exit 1
}
gh api "repos/${RUN_REPOSITORY}/actions/runs/${run_id}" > "${work}/run.json"
# Refuse failed/pending runs before requesting artifact downloads.
python3 "${scripts}/verify-promotion-manifest.py" --manifest "${manifest_file}" \
  --release-tag "${release_tag}" --snapshot-tag "${snapshot_tag}" \
  --uat-run-json "${work}/run.json" >/dev/null
if ! gh run download "${run_id}" --repo "${RUN_REPOSITORY}" \
    --name uat-artifact-manifest --dir "${work}/accepted"; then
  echo '::error::Cannot retrieve the successful UAT run artifact; refusing promotion.' >&2
  exit 1
fi
accepted="${work}/accepted/uat-artifact-manifest.json"
[[ -s "${accepted}" && ! -L "${accepted}" ]] || {
  echo '::error::Successful UAT run has no non-empty accepted artifact manifest.' >&2
  exit 1
}
python3 "${scripts}/verify-promotion-manifest.py" --manifest "${manifest_file}" \
  --release-tag "${release_tag}" --snapshot-tag "${snapshot_tag}" \
  --uat-run-json "${work}/run.json" --accepted-manifest "${accepted}"
