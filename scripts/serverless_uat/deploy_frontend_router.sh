#!/usr/bin/env bash
set -euo pipefail

FRONTEND_ROUTER_DIR="${FRONTEND_ROUTER_DIR:?FRONTEND_ROUTER_DIR must point to a checked-out frontend-router repository}"
CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG must point to the rendered GitOps routing manifest}"
release_tag="${FRONTEND_ROUTER_RELEASE_TAG:?FRONTEND_ROUTER_RELEASE_TAG must identify a project CI release}"
[[ "$release_tag" =~ ^(uat-daily-build-|daily-build-|v)[0-9][0-9A-Za-z._-]*$ ]] || {
  echo 'Frontend Router CD accepts release tags only, never a floating branch.' >&2
  exit 2
}

test -d "${FRONTEND_ROUTER_DIR}"
test -f "${CONFIG_FILE}"
test -x "${FRONTEND_ROUTER_DIR}/scripts/deploy_from_gitops.sh"

release_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/frontend-router-release.XXXXXX")"
gh release download "$release_tag" --repo ai-workspace-services/frontend-router \
  --pattern frontend-router-worker.js --pattern release-metadata.json --pattern SHA256SUMS \
  --dir "$release_dir"
# Check only the two explicit assets, never filenames supplied by an arbitrary
# checksum entry. Source identity must match the checked-out immutable tag.
awk '$2 == "frontend-router-worker.js" || $2 == "release-metadata.json" {print}' \
  "$release_dir/SHA256SUMS" > "$release_dir/verified-sums"
[[ "$(wc -l < "$release_dir/verified-sums" | tr -d ' ')" == 2 ]]
for asset in frontend-router-worker.js release-metadata.json; do
  [[ "$(awk -v name="$asset" '$2 == name {count++} END {print count+0}' "$release_dir/verified-sums")" == 1 ]]
done
(cd "$release_dir" && sha256sum -c verified-sums)
source_sha="$(git -C "$FRONTEND_ROUTER_DIR" rev-parse HEAD)"
jq -e --arg tag "$release_tag" --arg sha "$source_sha" \
  '.schema_version == 1 and .tag == $tag and .source_sha == $sha' \
  "$release_dir/release-metadata.json" >/dev/null
export FRONTEND_ROUTER_ARTIFACT_FILE="$release_dir/frontend-router-worker.js"
printf 'Deploying Frontend Router release %s at commit %s (prebuilt, no bundle).\n' "$release_tag" "$source_sha"

pushd "${FRONTEND_ROUTER_DIR}" >/dev/null
npm ci
FRONTEND_ROUTER_CONFIG_FILE="${CONFIG_FILE}" bash scripts/deploy_from_gitops.sh
popd >/dev/null
