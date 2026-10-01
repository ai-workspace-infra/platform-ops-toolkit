#!/usr/bin/env bash
# Record the digest UAT built and deployed for one Cloud Run service. The
# per-service records are merged into the UAT artifact manifest that a PROD
# promotion must copy by digest instead of rebuilding from source.
set -euo pipefail

: "${SERVICE:?SERVICE is required}"
: "${IMAGE:?IMAGE (registry repository without tag) is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"
: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"

[[ "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::${SERVICE}: the build did not report a sha256 image digest." >&2
  exit 1
}
source_sha="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
[[ "${source_sha}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::${SERVICE}: cannot resolve the built source commit." >&2
  exit 1
}

mkdir -p "${OUTPUT_DIR}"
jq -n --arg service "${SERVICE}" --arg image "${IMAGE}" --arg tag "${IMAGE_TAG}" \
  --arg digest "${IMAGE_DIGEST}" --arg source_sha "${source_sha}" \
  '{service:$service,image:$image,tag:$tag,digest:$digest,source_repository:("ai-workspace-services/" + $service),source_sha:$source_sha}' \
  > "${OUTPUT_DIR}/${SERVICE}.json"
echo "${SERVICE}: recorded ${IMAGE}@${IMAGE_DIGEST} from ${source_sha}."
