#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../platform-ops/provision/common_require_env.sh"
require_env DEPLOY_ENV GITHUB_OUTPUT
. "$(dirname "${BASH_SOURCE[0]}")/snapshot-tag-policy.sh"

resolved_tag="$(resolve_and_validate_snapshot_tag)"
printf 'snapshot_tag=%s\n' "${resolved_tag}" >> "${GITHUB_OUTPUT}"
printf 'deploy_env=%s\n' "${DEPLOY_ENV}" >> "${GITHUB_OUTPUT}"
echo "Snapshot preflight passed: ${resolved_tag} -> ${DEPLOY_ENV}."
