#!/usr/bin/env bash
# Toolkit final gate over provider facts returned by the fixed-SHA IaC owner.
set -euo pipefail

: "${CLOUD_RUN_SERVICE_NAME:?CLOUD_RUN_SERVICE_NAME is required}"
: "${EXPECTED_DIGEST:?EXPECTED_DIGEST is required}"
: "${LATEST_READY_REVISION:?LATEST_READY_REVISION is required}"
: "${TRAFFIC_REVISIONS:?TRAFFIC_REVISIONS is required}"
: "${SERVING_DIGEST:?SERVING_DIGEST is required}"

[[ "${EXPECTED_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME}: the expected digest is not sha256." >&2
  exit 1
}
[[ "${SERVING_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME}: the serving digest is not sha256." >&2
  exit 1
}
[[ -z "${LINUX_AMD64_CHILD_DIGEST:-}" || "${LINUX_AMD64_CHILD_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME}: the linux/amd64 child digest is not sha256." >&2
  exit 1
}

jq -e --arg revision "${LATEST_READY_REVISION}" \
  'type == "array" and all(.[]; type == "string" and . == $revision)' \
  <<<"${TRAFFIC_REVISIONS}" >/dev/null || {
  echo "::error::${CLOUD_RUN_SERVICE_NAME}: traffic still reaches a revision other than ${LATEST_READY_REVISION}." >&2
  exit 1
}

if [[ "${SERVING_DIGEST}" != "${EXPECTED_DIGEST}" && \
  "${SERVING_DIGEST}" != "${LINUX_AMD64_CHILD_DIGEST:-}" ]]; then
  echo "::error::${CLOUD_RUN_SERVICE_NAME} revision ${LATEST_READY_REVISION} serves ${SERVING_DIGEST}, not ${EXPECTED_DIGEST} or its linux/amd64 image." >&2
  exit 1
fi

echo "${CLOUD_RUN_SERVICE_NAME} revision ${LATEST_READY_REVISION} serves ${SERVING_DIGEST} (accepted artifact ${EXPECTED_DIGEST})."
