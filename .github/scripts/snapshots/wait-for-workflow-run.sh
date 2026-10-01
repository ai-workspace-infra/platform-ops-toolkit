#!/usr/bin/env bash
set -euo pipefail

# Wait for a dispatched child run and require an explicit `success`.
#
# A release is only as trustworthy as this wait, so it must not end early for
# reasons unrelated to the child:
# - Status is read with RUN_STATUS_TOKEN (the job's GITHUB_TOKEN, valid for the
#   whole job), not the GitHub App installation token used to dispatch, which
#   expires after 60 minutes while long UAT/PROD runs continue.
# - A transient API error (for example a 502) is retried within a bounded
#   budget instead of failing the release while the child keeps running.
# The child is never re-dispatched or cancelled here.

run_ref="${1:?run URL or ID is required}"
label="${2:?run label is required}"
timeout_seconds="${3:?wait timeout in seconds is required}"
repository="${RUN_REPOSITORY:?RUN_REPOSITORY must be set}"
interval_seconds="${RUN_POLL_INTERVAL_SECONDS:-30}"
max_read_failures="${RUN_MAX_READ_FAILURES:-10}"
status_token="${RUN_STATUS_TOKEN:-${GH_TOKEN:-}}"

[[ -n "${status_token}" ]] || {
  echo "::error::RUN_STATUS_TOKEN or GH_TOKEN must be set to read ${label} run status." >&2
  exit 2
}
for value in "${timeout_seconds}" "${interval_seconds}" "${max_read_failures}"; do
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
    echo "::error::Run wait timeout, poll interval and read-failure budget must be positive integers." >&2
    exit 2
  }
done
run_id="${run_ref##*/}"
[[ "${run_id}" =~ ^[0-9]+$ ]] || {
  echo "::error::Unable to determine ${label} run id from ${run_ref}." >&2
  exit 1
}

echo "Waiting for ${label} run ${run_ref}..."
started_at="${SECONDS}"
read_failures=0
while :; do
  if state="$(GH_TOKEN="${status_token}" gh api "repos/${repository}/actions/runs/${run_id}" \
      --jq '[.status, (.conclusion // "")] | @tsv' 2>/dev/null)"; then
    read_failures=0
    status="${state%%$'\t'*}"
    conclusion="${state#*$'\t'}"
    if [[ "${status}" == completed ]]; then
      if [[ "${conclusion}" != success ]]; then
        echo "::error::${label} run ${run_id} completed with ${conclusion:-no conclusion}." >&2
        exit 1
      fi
      echo "${label} run ${run_id} completed successfully."
      exit 0
    fi
    case "${status}" in
      queued|in_progress|waiting|pending|requested) ;;
      *)
        echo "::error::${label} run ${run_id} returned unexpected status ${status:-empty}." >&2
        exit 1
        ;;
    esac
  else
    read_failures=$((read_failures + 1))
    if (( read_failures >= max_read_failures )); then
      echo "::error::${label} run ${run_id} status was unreadable ${read_failures} times in a row." >&2
      exit 1
    fi
    echo "::warning::Could not read ${label} run ${run_id} status (${read_failures}/${max_read_failures}); still waiting." >&2
  fi

  if (( SECONDS - started_at >= timeout_seconds )); then
    echo "::error::Timed out waiting for ${label} run ${run_id} after ${timeout_seconds}s." >&2
    exit 1
  fi
  sleep "${interval_seconds}"
done
