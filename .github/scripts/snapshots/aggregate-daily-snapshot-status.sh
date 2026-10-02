#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/require-env.sh"
require_env SNAPSHOT_STATUS_DIRECTORY GITHUB_OUTPUT

deploy_env="${DEPLOY_ENV:-unknown}"
[[ "${deploy_env}" =~ ^(sit|uat|prod|unknown)$ ]] || {
  echo "::error::Unsupported DEPLOY_ENV: ${deploy_env}" >&2
  exit 2
}

shopt -s nullglob
files=("${SNAPSHOT_STATUS_DIRECTORY}"/*.jsonl)
if [[ "${#files[@]}" -eq 0 ]]; then
  echo 'snapshot_status=[]' >> "${GITHUB_OUTPUT}"
  if [[ -n "${SNAPSHOT_STATUS_OUTPUT:-}" ]]; then
    mkdir -p "$(dirname "${SNAPSHOT_STATUS_OUTPUT}")"
    printf '%s\n' '[]' > "${SNAPSHOT_STATUS_OUTPUT}"
  fi
  exit 0
fi

status_json="$(jq -sc '.' "${files[@]}")"
status_json="$(jq -c --arg environment "${deploy_env}" '[.[] | .environment = $environment]' <<<"${status_json}")"
echo "snapshot_status=${status_json}" >> "${GITHUB_OUTPUT}"

if [[ -n "${SNAPSHOT_STATUS_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "${SNAPSHOT_STATUS_OUTPUT}")"
  printf '%s\n' "${status_json}" > "${SNAPSHOT_STATUS_OUTPUT}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## 📊 Daily Snapshot Complete Repository Matrix'
    echo

    # Calculate overall status banner
    has_failed=$(jq -sr '[.[] | select(.status == "build_failed" or .status == "manifest_missing")] | length' "${files[@]}")
    has_pending=$(jq -sr '[.[] | select(.status == "build_timeout" or .status == "build_lookup_failed")] | length' "${files[@]}")

    if [[ "${has_failed}" -gt 0 ]]; then
      echo '### 🔴 Overall Build Status: FAILED'
    elif [[ "${has_pending}" -gt 0 ]]; then
      echo '### 🟡 Overall Build Status: IN PROGRESS / TIMEOUT'
    else
      echo '### 🟢 Overall Build Status: ALL SUCCEEDED'
    fi
    echo

    echo '| Environment | Status | Organization | Repository | Tag | Commit SHA | Details |'
    echo '|---|---|---|---|---|---|---|'
    jq -sr --arg environment "${deploy_env}" '
      map(.environment = $environment)
      | sort_by(.organization, .repository)
      | .[]
      | (
          if .status == "build_succeeded" or .status == "created" or .status == "tag_created" or .status == "dispatched" then "🟢 Success"
          elif .status == "unchanged" or .status == "planned" then "🟢 Tag Ready"
          elif .status == "build_failed" or .status == "manifest_missing" then "🔴 Failed"
          elif .status == "skipped" then "⚪ Skipped"
          else "🟡 Pending/Timeout"
          end
        ) as $badge
      | [ (.environment // "unknown"), $badge, .organization, .repository, .tag, (.sha[0:12] // "-"), .detail ]
      | map(tostring | gsub("\\|"; "\\\\|") | gsub("\\r?\\n"; " "))
      | "| " + join(" | ") + " |"
    ' "${files[@]}"
    echo
    echo '> **Status Legend:**'
    echo '> - 🟢 **Success / Tag Ready**: CI build succeeded, or snapshot tag created/verified.'
    echo '> - 🔴 **Failed**: CI build or release manifest creation failed.'
    echo '> - 🟡 **Pending/Timeout**: CI build lookup timed out or is still running.'
    echo '> - ⚪ **Skipped**: Repository default branch is not `main` or ref was not found.'
  } >> "${GITHUB_STEP_SUMMARY}"
fi
