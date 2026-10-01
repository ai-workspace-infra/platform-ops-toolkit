#!/usr/bin/env bash
# PROD Cloud Run images are the images UAT accepted, copied by digest (plan §7,
# GAP-16). Never rebuild from source here: a rebuild produces a different
# digest than the one UAT verified.
set -euo pipefail

: "${PROMOTION_MANIFEST:?PROMOTION_MANIFEST is required}"
: "${SERVICE:?SERVICE is required}"
: "${TARGET_IMAGE:?TARGET_IMAGE (registry repository without tag) is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

entry="$(jq -ce --arg service "${SERVICE}" '.images[] | select(.service == $service)' <<<"${PROMOTION_MANIFEST}")" || {
  echo "::error::${SERVICE}: the promotion manifest has no accepted UAT image." >&2
  exit 1
}
source_image="$(jq -r .image <<<"${entry}")"
digest="$(jq -r .digest <<<"${entry}")"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::${SERVICE}: the promotion manifest digest is not sha256." >&2
  exit 1
}

image_digest() {
  gcloud artifacts docker images describe "$1" --format='value(image_summary.digest)' 2>/dev/null || true
}

# Release tags are immutable: an existing tag must already be this digest.
existing="$(image_digest "${TARGET_IMAGE}:${IMAGE_TAG}")"
if [[ -n "${existing}" && "${existing}" != "${digest}" ]]; then
  echo "::error::${SERVICE}: ${TARGET_IMAGE}:${IMAGE_TAG} already holds ${existing}, not the UAT digest ${digest}; refusing to overwrite a release tag." >&2
  exit 1
fi
if [[ -z "${existing}" ]]; then
  # Server-side copy by digest: the manifest bytes, and therefore the digest,
  # are preserved.
  gcloud container images add-tag "${source_image}@${digest}" "${TARGET_IMAGE}:${IMAGE_TAG}" --quiet
fi

promoted="$(image_digest "${TARGET_IMAGE}:${IMAGE_TAG}")"
if [[ "${promoted}" != "${digest}" ]]; then
  echo "::error::${SERVICE}: ${TARGET_IMAGE}:${IMAGE_TAG} resolves to ${promoted:-nothing}, not the UAT digest ${digest}." >&2
  exit 1
fi
echo "${SERVICE}: ${TARGET_IMAGE}:${IMAGE_TAG} is the UAT-accepted ${digest}."
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'digest=%s\n' "${digest}" >> "${GITHUB_OUTPUT}"
fi
