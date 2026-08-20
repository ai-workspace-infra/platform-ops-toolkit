#!/usr/bin/env bash
set -euo pipefail

status_directory="${SNAPSHOT_STATUS_DIRECTORY:?SNAPSHOT_STATUS_DIRECTORY must be set}"
github_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

[[ -d "${status_directory}" ]] || {
  echo "::error::Snapshot status directory does not exist: ${status_directory}" >&2
  exit 2
}

mapfile -t tags < <(
  find "${status_directory}" -type f -name '*.jsonl' -exec jq -r \
    'select((.tag // "") != "") | .tag' {} + | sort -u
)

if [[ "${#tags[@]}" -ne 1 ]]; then
  echo "::error::Expected exactly one immutable snapshot tag, found ${#tags[@]}." >&2
  printf 'Observed tags: %s\n' "${tags[*]:-none}" >&2
  exit 2
fi

tag="${tags[0]}"
[[ "${tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::UAT automation requires an immutable daily-build tag, got: ${tag}" >&2
  exit 2
}

printf 'snapshot_tag=%s\n' "${tag}" >> "${github_output}"
echo "Resolved immutable UAT snapshot tag: ${tag}"
