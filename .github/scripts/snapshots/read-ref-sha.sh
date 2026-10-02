#!/usr/bin/env bash
# Read the commit SHA a GitHub ref lookup returns.
#
# Usage (from a script that defines the gh wrapper it passes):
#   . "$(dirname "${BASH_SOURCE[0]}")/read-ref-sha.sh"
#   existing="$(read_ref_sha gh api "repos/${repo}/git/ref/tags/${tag}" --jq '.object.sha')"
#
# `gh api` writes the error body to stdout and does not apply --jq to it, so a
# missing ref prints {"message":"Not Found",...,"status":"404"} and exits
# non-zero. Swallowing that exit status with `|| true` made the JSON look like
# an existing ref (Daily 36847896719 refused to "move" a release tag that did
# not exist). A ref exists only when the call succeeds and returns a 40-hex
# SHA; anything else prints nothing, meaning "no such ref".
read_ref_sha() {
  local output
  if output="$("$@" 2>/dev/null)" && [[ "${output}" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "${output}"
  fi
}
