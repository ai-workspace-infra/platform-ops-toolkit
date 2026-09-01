#!/usr/bin/env bash
set -euo pipefail

repo="${TARGET_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"
release_tag="${RELEASE_TAG:?RELEASE_TAG must be set}"
source_ref="${SNAPSHOT_SOURCE_REF:?SNAPSHOT_SOURCE_REF must be set}"
gh_token="${GH_TOKEN:?GH_TOKEN must be set}"

[[ "${release_tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?$ ]] || {
  echo "::error::RELEASE_TAG must be a formal immutable v* release tag." >&2
  exit 2
}
[[ "${source_ref}" =~ ^(v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?|uat-daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?)$ ]] || {
  echo "::error::SNAPSHOT_SOURCE_REF must be an existing verified release or UAT snapshot tag." >&2
  exit 2
}

export GH_TOKEN="${gh_token}"
source_sha="$(gh api "repos/${repo}/commits/${source_ref}" --jq .sha)"
existing_sha="$(gh api "repos/${repo}/git/ref/tags/${release_tag}" --jq '.object.sha // empty' 2>/dev/null || true)"

if [[ -n "${existing_sha}" ]]; then
  [[ "${existing_sha}" == "${source_sha}" ]] || {
    echo "::error::Refusing to move ${repo}:${release_tag}; it already points to ${existing_sha}." >&2
    exit 1
  }
  echo "Control-plane release tag already exists at ${source_sha}: ${repo}:${release_tag}"
  exit 0
fi

gh api --method POST "repos/${repo}/git/refs" \
  -f "ref=refs/tags/${release_tag}" \
  -f "sha=${source_sha}"
echo "Created control-plane release tag ${repo}:${release_tag} at ${source_sha}"
