#!/usr/bin/env bash
set -euo pipefail

tag="${TAG_NAME:-${GITHUB_REF_NAME:-}}"
if [[ -z "${tag}" ]]; then
  echo "::error::Missing TAG_NAME or GITHUB_REF_NAME" >&2
  exit 1
fi

echo "Checking if release for tag '${tag}' already exists..."
if gh release view "${tag}" >/dev/null 2>&1; then
  echo "Release for tag '${tag}' already exists."
else
  echo "Creating GitHub release for tag '${tag}' with automated release notes..."
  gh release create "${tag}" \
    --title "${tag}" \
    --generate-notes \
    --verify-tag
  echo "Release for tag '${tag}' successfully created."
fi
