#!/usr/bin/env bash
# Prove the serving Cloud Run revision runs the expected image digest: the
# digest UAT built, or in PROD the digest UAT accepted. A tag is not evidence.
set -euo pipefail

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
: "${GCP_REGION:?GCP_REGION is required}"
: "${CLOUD_RUN_SERVICE_NAME:?CLOUD_RUN_SERVICE_NAME is required}"
: "${EXPECTED_DIGEST:?EXPECTED_DIGEST is required}"

[[ "${EXPECTED_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME}: the expected digest is not sha256." >&2
  exit 1
}

service="$(gcloud run services describe "${CLOUD_RUN_SERVICE_NAME}" \
  --project="${GCP_PROJECT_ID}" --region="${GCP_REGION}" --format=json)"
revision="$(jq -r '.status.latestReadyRevisionName // empty' <<<"${service}")"
[[ -n "${revision}" ]] || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME} has no ready revision." >&2
  exit 1
}
# Every revision that receives traffic must be the verified one.
stray="$(jq -r --arg revision "${revision}" \
  '[.status.traffic[]? | select((.percent // 0) > 0) | select((.revisionName // $revision) != $revision)] | length' <<<"${service}")"
[[ "${stray}" == 0 ]] || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME}: traffic still reaches a revision other than ${revision}." >&2
  exit 1
}

image="$(gcloud run revisions describe "${revision}" \
  --project="${GCP_PROJECT_ID}" --region="${GCP_REGION}" --format='value(status.imageDigest)')"
if [[ "${image}" != *"@${EXPECTED_DIGEST}" ]]; then
  echo "::error::${CLOUD_RUN_SERVICE_NAME} revision ${revision} runs ${image:-an unknown image}, not ${EXPECTED_DIGEST}." >&2
  exit 1
fi
echo "${CLOUD_RUN_SERVICE_NAME} revision ${revision} serves ${EXPECTED_DIGEST}."
