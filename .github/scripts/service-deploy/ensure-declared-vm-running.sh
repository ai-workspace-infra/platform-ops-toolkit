#!/usr/bin/env bash
set -euo pipefail

# Shared service VMs are Spot instances with instance_termination_action=STOP,
# so a preemption leaves them TERMINATED and Terraform still reports no change.
# Start (or resume) only the existing, GitOps-declared instance and wait for
# RUNNING. This never creates, replaces or deletes an instance or its disks;
# a missing instance fails the describe call.

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${NODE_NAME:?NODE_NAME is required}"
: "${NODE_ZONE:?NODE_ZONE is required}"
timeout="${VM_START_TIMEOUT_SECONDS:-300}"
interval="${VM_START_POLL_SECONDS:-5}"

vm_status() {
  gcloud compute instances describe "${NODE_NAME}" \
    --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --format='value(status)'
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
        echo "GCP VM ${NODE_NAME} is ${status}; starting the existing instance (nothing is created or replaced)"
        gcloud compute instances start "${NODE_NAME}" --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --quiet
        requested=true
      fi
      ;;
    SUSPENDED)
      if [[ "${requested}" == false ]]; then
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
