#!/usr/bin/env bash

# Resolve and validate the tag/environment pair before any matrix job can
# create a cross-repository ref.  Stable release tags and daily snapshots use
# the same tagging implementation, but they are different release classes.
resolve_and_validate_snapshot_tag() {
  local tag="${SNAPSHOT_TAG:-daily-build-$(date -u +%Y.%m.%d)}"
  tag="$(printf '%s' "${tag}" | tr -d '\r\n' | xargs)"

  [[ "${tag}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
    echo "::error::Invalid snapshot tag: ${tag}" >&2
    return 2
  }

  case "${tag}" in
    v[0-9A-Za-z._/-]*)
      [[ "${DEPLOY_ENV}" == prod ]] || {
        echo "::error::v* release tags require deploy_env=prod; release publication is manually controlled." >&2
        return 2
      }
      ;;
    daily-build-[0-9A-Za-z._/-]*|uat-daily-build-[0-9A-Za-z._/-]*)
      [[ "${DEPLOY_ENV}" =~ ^(sit|uat)$ ]] || {
        echo "::error::daily-build-* and uat-daily-build-* require deploy_env=sit or uat; use v* with prod for a release." >&2
        return 2
      }
      ;;
    *)
      echo "::error::Snapshot tag must match daily-build-*, uat-daily-build-*, or a controlled v* release tag." >&2
      return 2
      ;;
  esac

  printf '%s\n' "${tag}"
}
