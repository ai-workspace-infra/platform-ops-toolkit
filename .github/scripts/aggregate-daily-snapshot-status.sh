#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env SNAPSHOT_STATUS_DIRECTORY GITHUB_OUTPUT

shopt -s nullglob
files=("${SNAPSHOT_STATUS_DIRECTORY}"/*.jsonl)
if [[ "${#files[@]}" -eq 0 ]]; then
  echo 'snapshot_status=[]' >> "${GITHUB_OUTPUT}"
  exit 0
fi

status_json="$(jq -sc '.' "${files[@]}")"
echo "snapshot_status=${status_json}" >> "${GITHUB_OUTPUT}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## Daily snapshot matrix'
    echo
    echo '| Organization | Repository | Tag | SHA | Status | Detail |'
    echo '|---|---|---|---|---|---|'
    jq -sr '
      sort_by(.organization, .repository)
      | .[]
      | [ .organization, .repository, .tag, (.sha[0:12] // ""), .status, .detail ]
      | map(tostring | gsub("\\|"; "\\\\|") | gsub("\\r?\\n"; " "))
      | "| " + join(" | ") + " |"
    ' "${files[@]}"
    echo
    echo '> Status is reported per organization/repository. A repository may have multiple rows when tag creation and build dispatch are separate operations.'
  } >> "${GITHUB_STEP_SUMMARY}"
fi
