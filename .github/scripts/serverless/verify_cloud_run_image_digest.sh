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

# Buildx pushes an OCI image index (the image plus its provenance
# attestation) and reports the index digest, while Cloud Run records the
# linux/amd64 image manifest it resolved from that index. The index digest
# fixes its children, so accept exactly the expected digest and its single
# linux/amd64 child as read from the registry, nothing else.
accepted=("${EXPECTED_DIGEST}")
if [[ -n "${IMAGE:-}" ]]; then
  raw="$(docker buildx imagetools inspect --raw "${IMAGE}@${EXPECTED_DIGEST}")" || {
    echo "::error::${CLOUD_RUN_SERVICE_NAME}: cannot read ${IMAGE}@${EXPECTED_DIGEST} from the registry." >&2
    exit 1
  }
  child="$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest]
    | if length == 1 then .[0] elif length == 0 then "" else error("several linux/amd64 manifests") end' <<<"${raw}")" || {
    echo "::error::${CLOUD_RUN_SERVICE_NAME}: ${IMAGE}@${EXPECTED_DIGEST} has an ambiguous linux/amd64 manifest." >&2
    exit 1
  }
  if [[ -n "${child}" ]]; then
    [[ "${child}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "::error::${CLOUD_RUN_SERVICE_NAME}: the linux/amd64 manifest digest is malformed." >&2
      exit 1
    }
    accepted+=("${child}")
  fi
fi

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
for digest in "${accepted[@]}"; do
  if [[ "${image}" == *"@${digest}" ]]; then
    echo "${CLOUD_RUN_SERVICE_NAME} revision ${revision} serves ${digest} (accepted artifact ${EXPECTED_DIGEST})."
    exit 0
  fi
done
echo "::error::${CLOUD_RUN_SERVICE_NAME} revision ${revision} runs ${image:-an unknown image}, not ${EXPECTED_DIGEST} or its linux/amd64 image." >&2
exit 1
