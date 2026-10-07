#!/usr/bin/env bash
set -euo pipefail

directory="${DISPATCH_STATUS_DIRECTORY:?DISPATCH_STATUS_DIRECTORY is required}"
output="${DISPATCH_STATUS_OUTPUT:?DISPATCH_STATUS_OUTPUT is required}"
environment="${DEPLOY_ENV:?DEPLOY_ENV is required}"

shopt -s nullglob
files=("${directory}"/*.json)
[[ "${#files[@]}" -gt 0 ]] || {
  echo "::error::No dispatch receipts were found for ${environment}." >&2
  exit 1
}

summary="$(jq -sc --arg environment "${environment}" '[.[] | select(.environment == $environment)]' "${files[@]}")"
[[ "${summary}" != '[]' ]] || {
  echo "::error::Dispatch receipts do not match selected environment ${environment}." >&2
  exit 1
}
mkdir -p "$(dirname "${output}")"
printf '%s\n' "${summary}" > "${output}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## Environment dispatch matrix'
    echo
    echo '| Environment | Operation | Workflow | Result | Run |'
    echo '|---|---|---|---|---|'
    jq -r '.[] | "| \(.environment) | \(.operation) | \(.workflow) | \(.result) | \(.run_url // "-") |"' <<<"${summary}"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if jq -e 'any(.[]; .result != "success")' <<<"${summary}" >/dev/null; then
  echo "::error::Environment dispatch validation failed for ${environment}." >&2
  exit 1
fi
