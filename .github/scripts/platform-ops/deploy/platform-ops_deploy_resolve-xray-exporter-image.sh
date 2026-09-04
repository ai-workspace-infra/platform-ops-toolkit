#!/bin/bash
set -euo pipefail

# Keep the manual dispatch UI to one exporter field.  A slash is valid in a
# GitHub repository name, so '@' is the only supported repository/tag
# separator: owner/repository@tag.
deployment_env="${DEPLOYMENT_ENV:?DEPLOYMENT_ENV is required}"
deploy_tag="${DEPLOY_TAG:-}"

release_tags=""
load_release_tags() {
  local repository="$1"
  local release_json="${XRAY_EXPORTER_RELEASES_JSON:-}"
  if [[ -z "${release_json}" ]]; then
    local api_url="https://api.github.com/repos/${repository}/releases?per_page=100"
    local curl_args=(
      --fail --silent --show-error --location
      --retry 3 --connect-timeout 10 --max-time 30
      -H 'Accept: application/vnd.github+json'
      -H 'X-GitHub-Api-Version: 2022-11-28'
    )
    if [[ -n "${GH_TOKEN:-}" ]]; then
      curl_args+=( -H "Authorization: Bearer ${GH_TOKEN}" )
    fi
    release_json="$(curl "${curl_args[@]}" "${api_url}")" || {
      echo "::error::Unable to query Xray Exporter releases for ${deploy_tag}. Pass xray_exporter_image explicitly." >&2
      exit 1
    }
  fi

  # Test fixtures may omit assets. Live releases must contain both Linux
  # architectures because UAT and PROD Agent Proxy nodes can run on either
  # amd64 VPS hosts or AWS T4G arm64 hosts.
  release_tags="$(jq -r '
    .[]
    | select(
        (.tag_name | startswith("daily-build-")) or
        (.tag_name | startswith("uat-daily-build-"))
      )
    | select(
        (.assets | type != "array") or
        (
          any(.assets[]?.name; . == "xray-exporter-linux-amd64") and
          any(.assets[]?.name; . == "xray-exporter-linux-arm64")
        )
      )
    | .tag_name
  ' <<<"${release_json}" | sort -V)"
}

latest_release_at_or_before() {
  local upper_bound="${1:-}"
  local candidates="${2:-${release_tags}}"
  local selected=""
  local candidate
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if [[ -z "${upper_bound}" || "${candidate}" < "${upper_bound}" || "${candidate}" == "${upper_bound}" ]]; then
      selected="${candidate}"
    fi
  done <<<"${candidates}"
  printf '%s' "${selected}"
}

case "${deployment_env}" in
  uat)
    default_repository="ai-workspace-xstream/xray-exporter"
    default_version="${deploy_tag:?UAT Xray Exporter requires DEPLOY_TAG}"
    # Application images may use daily-build-YYYY.MM.DD[-rN] or the full
    # uat-daily-build-YYYY.MM.DD-rN tag. The snapshot inventory creates the
    # same daily tag in this repository, so prefer an exact exporter release;
    # retain the older uat-daily fallback for historical snapshots.
    if [[ -z "${INPUT_XRAY_EXPORTER_IMAGE:-}" && ( \
      "${default_version}" =~ ^daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[0-9]+)?$ || \
      "${default_version}" =~ ^uat-daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[0-9]+$ \
    ) ]]; then
      load_release_tags "${default_repository}"
      requested_version="${default_version}"
      if grep -Fxq "${default_version}" <<<"${release_tags}"; then
        :
      elif [[ "${default_version}" =~ ^daily-build- ]]; then
        uat_release_tags="$(grep -E '^uat-daily-build-' <<<"${release_tags}" || true)"
        release_prefix="uat-${default_version}-r"
        if [[ "${default_version}" =~ -r[0-9]+$ ]]; then
          translated_version="uat-${default_version}"
          if grep -Fxq "${translated_version}" <<<"${uat_release_tags}"; then
            default_version="${translated_version}"
          else
            default_version="$(latest_release_at_or_before "${translated_version}" "${uat_release_tags}")"
          fi
        else
          fallback_bound="uat-${default_version#daily-build-}-r999999"
          matching_tags="$(grep -E "^${release_prefix}[0-9]+$" <<<"${uat_release_tags}" || true)"
          default_version="$(latest_release_at_or_before "" "${matching_tags}")"
        fi
        # If this date has no exporter build yet, fall back to the latest
        # exporter release available before the application build date.
        if [[ -z "${default_version}" ]]; then
          default_version="$(latest_release_at_or_before "${fallback_bound:-${translated_version:-}}" "${uat_release_tags}")"
        fi
      else
        if grep -Fxq "${default_version}" <<<"${release_tags}"; then
          :
        else
          default_version="$(latest_release_at_or_before "${default_version}")"
        fi
      fi
      if [[ -z "${default_version}" ]]; then
        echo "::error::No usable UAT Xray Exporter release is available for ${requested_version}. Pass xray_exporter_image explicitly." >&2
        exit 1
      fi
      if [[ "${default_version}" != "${requested_version}" ]]; then
        echo "::warning::No exact UAT Xray Exporter release for ${requested_version}; using ${default_version}."
      fi
      echo "Resolved UAT Xray Exporter ${default_version} for application tag ${deploy_tag}."
    fi
    ;;
  prod)
    default_repository="ai-workspace-xstream/xray-exporter"
    default_version=""
    if [[ -z "${INPUT_XRAY_EXPORTER_IMAGE:-}" ]]; then
      if [[ ! "${deploy_tag}" =~ ^v([0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[0-9]+)?$ ]]; then
        echo "::error::PROD Xray Exporter auto-resolution requires a date release tag (vYYYY.MM.DD[-rN]); pass xray_exporter_image explicitly for ${deploy_tag}." >&2
        exit 1
      fi

      release_date="${BASH_REMATCH[1]}"
      load_release_tags "${default_repository}"
      daily_release_tags="$(grep -E '^daily-build-' <<<"${release_tags}" || true)"
      same_day_tags="$(grep -E "^daily-build-${release_date}(-r[0-9]+)?$" <<<"${daily_release_tags}" || true)"
      default_version="$(latest_release_at_or_before "" "${same_day_tags}")"

      # A production release may run before that day's exporter build. In
      # that case use the newest immutable daily release no later than the
      # production date; never fall back to the upstream metrics-only binary.
      if [[ -z "${default_version}" ]]; then
        default_version="$(latest_release_at_or_before "daily-build-${release_date}-r999999" "${daily_release_tags}")"
      fi
      if [[ -z "${default_version}" ]]; then
        echo "::error::No snapshot-capable PROD Xray Exporter release is available for ${deploy_tag}. Pass xray_exporter_image explicitly." >&2
        exit 1
      fi
      echo "Resolved PROD Xray Exporter ${default_version} for application tag ${deploy_tag}."
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
