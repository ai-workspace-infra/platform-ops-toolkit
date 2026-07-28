#!/usr/bin/env bash
# A shell script committed as 100644 and invoked bare from a workflow
# (`run: .github/scripts/foo.sh`) fails with "Permission denied" and exit 126.
# The step's log shows only its env block -- no error text worth grepping for,
# and nothing in review flags the mode. Assert the invariant instead.
set -euo pipefail

bad=()
while IFS= read -r line; do
  mode="${line%% *}"
  path="${line#*$'\t'}"
  [[ "${mode}" == "100755" ]] || bad+=("${mode} ${path}")
done < <(git ls-files -s '*.sh')

if [[ "${#bad[@]}" -gt 0 ]]; then
  echo "::error::Shell scripts tracked without the executable bit — a bare 'run: <path>' will exit 126 Permission denied:" >&2
  for entry in "${bad[@]}"; do
    echo "::error::  ${entry}" >&2
  done
  echo "::error::Fix with: git update-index --chmod=+x <path>" >&2
  exit 1
fi

echo "All $(git ls-files '*.sh' | wc -l | tr -d ' ') tracked shell scripts are mode 100755."
