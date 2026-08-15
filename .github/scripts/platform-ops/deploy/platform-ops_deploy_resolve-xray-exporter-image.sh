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
    # Application images use the shared daily-build-YYYY.MM.DD tag, while the
    # UAT exporter publishes the same build under a release tag with an
    # explicit retry suffix (uat-daily-build-YYYY.MM.DD-rN). Resolve the latest
    # matching exporter release instead of constructing a URL that does not
    # exist and failing later with a remote HTTP 404.
    if [[ "${default_version}" =~ ^daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then
      release_json="${XRAY_EXPORTER_RELEASES_JSON:-}"
      if [[ -z "${release_json}" ]]; then
        api_url="https://api.github.com/repos/${default_repository}/releases?per_page=100"
        curl_args=(
          --fail --silent --show-error --location
          --retry 3 --connect-timeout 10 --max-time 30
          -H 'Accept: application/vnd.github+json'
          -H 'X-GitHub-Api-Version: 2022-11-28'
        )
        if [[ -n "${GH_TOKEN:-}" ]]; then
          curl_args+=( -H "Authorization: Bearer ${GH_TOKEN}" )
        fi
        release_json="$(curl "${curl_args[@]}" "${api_url}")" || {
          echo "::error::Unable to query Xray Exporter releases for ${default_version}. Pass xray_exporter_image explicitly." >&2
          exit 1
        }
      fi

      release_prefix="uat-${default_version}-r"
      default_version="$(jq -r --arg prefix "${release_prefix}" '
        [ .[]
          | .tag_name
          | select(startswith($prefix))
          | select((.[($prefix | length):] | test("^[0-9]+$")))
        ] | .[]
      ' <<<"${release_json}" | sort -V | tail -n 1)"
      if [[ -z "${default_version}" ]]; then
        echo "::error::No UAT Xray Exporter release matches ${release_prefix}<retry>. Pass xray_exporter_image explicitly." >&2
        exit 1
      fi
      echo "Resolved UAT Xray Exporter ${default_version} for application tag ${deploy_tag}."
    fi
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
