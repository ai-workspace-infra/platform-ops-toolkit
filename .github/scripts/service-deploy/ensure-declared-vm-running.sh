#!/usr/bin/env bash
set -euo pipefail

# Shared service nodes are standard (vault_vm) instances with reserved static
# IPs. If one was stopped (TERMINATED), Terraform still reports no change, so
# record when and how it stopped, then start (or resume) only the existing,
# GitOps-declared instance and wait for RUNNING. This never creates, replaces
# or deletes an instance or its disks; a missing instance fails the describe.

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${NODE_NAME:?NODE_NAME is required}"
: "${NODE_ZONE:?NODE_ZONE is required}"
timeout="${VM_START_TIMEOUT_SECONDS:-300}"
interval="${VM_START_POLL_SECONDS:-5}"

vm_status() {
  gcloud compute instances describe "${NODE_NAME}" \
    --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --format='value(status)'
}

# Evidence only: operation type and time, never the acting principal (the
# Actions log is public). A missing list permission must not block recovery.
report_stop() {
  local operations
  echo "GCP VM ${NODE_NAME} stop record: $(gcloud compute instances describe "${NODE_NAME}" \
    --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --format='value(lastStopTimestamp,lastSuspendedTimestamp)')"
  if operations="$(gcloud compute operations list --project="${PROJECT_ID}" \
      --zones="${NODE_ZONE}" --filter="targetLink~/instances/${NODE_NAME}\$" \
      --sort-by=~insertTime --limit=5 --format='value(insertTime,operationType,status)')"; then
    echo "Recent operations on ${NODE_NAME}:"
    echo "${operations}"
  else
    echo "::warning::Could not list GCP operations for ${NODE_NAME}; check Cloud Audit Logs for the stop cause"
  fi
}

deadline=$((SECONDS + timeout))
requested=false
while true; do
  status="$(vm_status)"
  case "${status}" in
    RUNNING)
      echo "GCP VM ${NODE_NAME} (${NODE_ZONE}) is RUNNING"
      exit 0
      ;;
    TERMINATED|STOPPED)
      if [[ "${requested}" == false ]]; then
        report_stop
        echo "GCP VM ${NODE_NAME} is ${status}; starting the existing instance (nothing is created or replaced)"
        gcloud compute instances start "${NODE_NAME}" --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --quiet
        requested=true
      fi
      ;;
    SUSPENDED)
      if [[ "${requested}" == false ]]; then
        report_stop
        echo "GCP VM ${NODE_NAME} is SUSPENDED; resuming the existing instance"
        gcloud compute instances resume "${NODE_NAME}" --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --quiet
        requested=true
      fi
      ;;
    PROVISIONING|STAGING|STOPPING|SUSPENDING|REPAIRING|PENDING_STOP)
      ;;
    *)
      echo "::error::GCP VM ${NODE_NAME} has unexpected status '${status}'" >&2
      exit 1
      ;;
  esac
  if (( SECONDS >= deadline )); then
    echo "::error::GCP VM ${NODE_NAME} did not become RUNNING within ${timeout}s (status=${status})" >&2
    exit 1
  fi
  echo "Waiting for GCP VM ${NODE_NAME} (status=${status})"
  sleep "${interval}"
done
