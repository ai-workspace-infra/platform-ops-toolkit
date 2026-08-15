#!/usr/bin/env bash
set -euo pipefail

: "${VULTR_API_KEY:?VULTR_API_KEY is required}"
: "${INSTANCE_ID:?INSTANCE_ID is required}"

payload="$(jq -n --arg instance_id "${INSTANCE_ID}" '{instance_id: $instance_id}')"
snapshot_id="$(curl -fsS --retry 3 -X POST \
  -H "Authorization: Bearer ${VULTR_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "${payload}" \
  https://api.vultr.com/v2/snapshots | jq -r '.snapshot.id // empty')"

[[ -n "${snapshot_id}" ]] || {
  echo "::error::Vultr did not return a snapshot ID" >&2
  exit 1
}

for attempt in $(seq 1 60); do
  status="$(curl -fsS --retry 3 -H "Authorization: Bearer ${VULTR_API_KEY}" \
    "https://api.vultr.com/v2/snapshots/${snapshot_id}" | jq -r '.snapshot.status // empty')"
  echo "Snapshot ${snapshot_id}: ${status} (${attempt}/60)"
  [[ "${status}" == complete ]] && break
  [[ "${status}" == error ]] && exit 1
  sleep 30
done

[[ "${status}" == complete ]] || {
  echo "::error::Snapshot did not complete before timeout" >&2
  exit 1
}

echo "snapshot_id=${snapshot_id}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
