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
