#!/usr/bin/env bash
set -euo pipefail

status_directory="${SNAPSHOT_STATUS_DIRECTORY:?SNAPSHOT_STATUS_DIRECTORY must be set}"
github_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

[[ -d "${status_directory}" ]] || {
  echo "::error::Snapshot status directory does not exist: ${status_directory}" >&2
  exit 2
}

# The services organization is the deployable web-saas snapshot that drives
# the combined UAT dispatch.  Lab/xstream entries may legitimately retain an
# older tag when their provider-owned artifact was unchanged; treating those
# tags as part of the canonical set would make a complete snapshot look
# ambiguous and would either deploy the wrong revision or halt unnecessarily.
canonical_organization="${SNAPSHOT_CANONICAL_ORGANIZATION:-ai-workspace-services}"
mapfile -t tags < <(
  find "${status_directory}" -type f -name '*.jsonl' -exec jq -r \
    --arg organization "${canonical_organization}" \
    'select(.organization == $organization and (.tag // "") != "") | .tag' {} + | sort -u
)

if [[ "${#tags[@]}" -ne 1 ]]; then
  echo "::error::Expected exactly one immutable ${canonical_organization} snapshot tag, found ${#tags[@]}." >&2
  printf 'Observed canonical tags: %s\n' "${tags[*]:-none}" >&2
  exit 2
fi

tag="${tags[0]}"
[[ "${tag}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::UAT automation requires an immutable daily-build tag, got: ${tag}" >&2
  exit 2
}

mapfile -t provider_tags < <(
  find "${status_directory}" -type f -name '*.jsonl' -exec jq -r \
    --arg organization "${canonical_organization}" \
    'select((.organization // "") != $organization and (.tag // "") != "") | .tag' {} + | sort -u
)
if [[ "${#provider_tags[@]}" -gt 0 ]]; then
  printf 'Provider-owned snapshot tags (not used for UAT dispatch): %s\n' \
    "${provider_tags[*]}"
fi

printf 'snapshot_tag=%s\n' "${tag}" >> "${github_output}"
echo "Resolved immutable UAT snapshot tag: ${tag}"
