#!/usr/bin/env bash
# PROD Cloud Run promotes the digests a successful UAT Hybrid run accepted; it
# never rebuilds from source (plan §7, GAP-16, TC-10). Outside PROD a
# promotion manifest is refused so UAT cannot be pinned to foreign images.
set -euo pipefail

: "${VAULT_ENV_PATH:?VAULT_ENV_PATH is required}"
: "${DEPLOYS_CLOUD_RUN:?DEPLOYS_CLOUD_RUN is required}"
manifest="${PROMOTION_MANIFEST:-}"

if [[ "${VAULT_ENV_PATH}" != prod ]]; then
  if [[ -n "${manifest}" ]]; then
    echo "::error::promotion_manifest is only accepted for a PROD Cloud Run promotion." >&2
    exit 1
  fi
  exit 0
fi
[[ "${DEPLOYS_CLOUD_RUN}" == true ]] || exit 0

if [[ -z "${manifest}" ]]; then
  echo "::error::PROD Cloud Run requires the UAT-accepted promotion_manifest; rebuilding from source is not a promotion." >&2
  exit 1
fi
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${GH_TOKEN:?GH_TOKEN is required to read the UAT Hybrid run}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf '%s' "${manifest}" > "${work}/manifest.json"
run_id="$(jq -r '.uat_run_id // empty' "${work}/manifest.json" 2>/dev/null || true)"
[[ "${run_id}" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::Refusing PROD promotion: the manifest does not name its UAT Hybrid run." >&2
  exit 1
}
# Re-read the UAT verdict here as well: a PROD dispatch with a hand-made
# manifest must not bypass the Daily gate.
gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}" > "${work}/uat-run.json"
python3 "$(dirname "${BASH_SOURCE[0]}")/../snapshots/verify-promotion-manifest.py" \
  --manifest "${work}/manifest.json" --release-tag "${RELEASE_TAG}" \
  --uat-run-json "${work}/uat-run.json" >/dev/null
echo "PROD promotion manifest verified against successful UAT Hybrid run ${run_id}."
