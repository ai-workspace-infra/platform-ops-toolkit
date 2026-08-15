#!/bin/bash
set -euo pipefail

# Keep the manual dispatch UI to one exporter field.  A slash is valid in a
# GitHub repository name, so '@' is the only supported repository/tag
# separator: owner/repository@tag.
deployment_env="${DEPLOYMENT_ENV:?DEPLOYMENT_ENV is required}"
deploy_tag="${DEPLOY_TAG:-}"

case "${deployment_env}" in
  uat)
    default_repository="ai-workspace-xstream/xray-exporter"
    default_version="${deploy_tag:?UAT Xray Exporter requires DEPLOY_TAG}"
    ;;
  *)
    default_repository="compassvpn/xray-exporter"
    default_version="v0.6.0"
    ;;
esac

image="${INPUT_XRAY_EXPORTER_IMAGE:-${default_repository}@${default_version}}"
if [[ "${image}" != *@* ]]; then
  echo "::error::xray_exporter_image must use owner/repository@tag; received an invalid value." >&2
  exit 1
fi

repository="${image%@*}"
version="${image##*@}"
if [[ -z "${repository}" || -z "${version}" || "${repository}" == */ || "${version}" == */* ]]; then
  echo "::error::xray_exporter_image must use owner/repository@tag; received an invalid value." >&2
  exit 1
fi

echo "repository=${repository}" >> "${GITHUB_OUTPUT}"
echo "version=${version}" >> "${GITHUB_OUTPUT}"
