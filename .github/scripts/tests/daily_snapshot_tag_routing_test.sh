#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${script_dir}/../snapshots/tag-daily-main-snapshot.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

assert_rejected() {
  local tag="$1" env_name="$2" expected="$3"
  if GH_TOKEN=test-token DEPLOY_ENV="${env_name}" SNAPSHOT_TAG="${tag}" \
    SNAPSHOT_ORGS=ai-workspace-infra bash "${script}" >"${workdir}/out" 2>&1; then
    echo "expected rejection for ${tag} with ${env_name}" >&2
    exit 1
  fi
  grep -Fq "${expected}" "${workdir}/out"
}

assert_rejected "v2026.08.15.1" uat "v* release tags require deploy_env=prod"
assert_rejected "daily-build-2026.08.15-r1" prod "require deploy_env=sit or uat"
echo "daily snapshot tag routing safeguards passed"
