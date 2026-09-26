#!/usr/bin/env bash
set -euo pipefail

# A release tag can become visible in GitHub before the service image published
# by the application repository reaches Artifact Registry.  Do not turn that
# normal cross-repository propagation window into a Cloud Run "image not
# found" failure.

project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set}"
registry_region="${GCP_ARTIFACT_REGISTRY_REGION:?GCP_ARTIFACT_REGISTRY_REGION must be set}"
service="${CLOUD_RUN_SERVICE:?CLOUD_RUN_SERVICE must be set}"
image_tag="${IMAGE_TAG:?IMAGE_TAG must be set}"
attempts="${ARTIFACT_IMAGE_WAIT_ATTEMPTS:-30}"
interval_seconds="${ARTIFACT_IMAGE_WAIT_INTERVAL_SECONDS:-10}"

if [[ ! "${attempts}" =~ ^[1-9][0-9]*$ || ! "${interval_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ARTIFACT_IMAGE_WAIT_ATTEMPTS and ARTIFACT_IMAGE_WAIT_INTERVAL_SECONDS must be positive integers" >&2
  exit 2
fi

image_uri="${registry_region}-docker.pkg.dev/${project_id}/serverless/${service}:${image_tag}"

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if digest="$(gcloud artifacts docker images describe "${image_uri}" --format='value(image_summary.digest)' 2>/dev/null)" && [[ -n "${digest}" ]]; then
    echo "Artifact Registry image is ready: ${registry_region}/serverless/${service}:${image_tag} (${digest})"
    exit 0
  fi

  # Workload Identity Federation can allow the caller to read the tag while
  # the image-summary endpoint briefly returns no digest (for example while a
  # pushed multi-platform manifest is being indexed).  The exact tag is still
  # an authoritative readiness signal for the following Cloud Run deploy.
  if tags="$(gcloud artifacts docker tags list \
    "${registry_region}-docker.pkg.dev/${project_id}/serverless/${service}" \
    --filter="tag:${image_tag}" \
    --format='value(tag)' 2>/dev/null)"; then
    tag_ready=false
    while IFS= read -r tag; do
      if [[ "${tag}" == "${image_tag}" ]]; then
        tag_ready=true
        break
      fi
    done <<< "${tags}"

    if [[ "${tag_ready}" == true ]]; then
      echo "Artifact Registry tag is ready: ${registry_region}/serverless/${service}:${image_tag}"
      exit 0
    fi
  fi

  if (( attempt < attempts )); then
    echo "Waiting for Artifact Registry image (${attempt}/${attempts}): ${registry_region}/serverless/${service}:${image_tag}"
    sleep "${interval_seconds}"
  fi
done

echo "Artifact Registry image did not become available before timeout: ${image_uri}" >&2
echo "The application release workflow must publish this exact tag before Cloud Run deployment can proceed." >&2
exit 1
