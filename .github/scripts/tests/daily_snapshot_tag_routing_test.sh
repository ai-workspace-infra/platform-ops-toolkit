#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${script_dir}/../snapshots/tag-daily-main-snapshot.sh"
preflight_script="${script_dir}/../snapshots/validate-daily-snapshot-input.sh"
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
assert_rejected "uat-daily-build-2026.08.15-r1" prod "require deploy_env=sit or uat"

preflight_output="$(mktemp)"
preflight_log="${workdir}/preflight.log"
GH_TOKEN=test-token DEPLOY_ENV=prod SNAPSHOT_TAG=v2026.08.15.2 \
  GITHUB_OUTPUT="${preflight_output}" bash "${preflight_script}" >"${preflight_log}"
grep -Fqx "snapshot_tag=v2026.08.15.2" "${preflight_output}"
grep -Fqx "deploy_env=prod" "${preflight_output}"
rm -f "${preflight_output}"

if GH_TOKEN=test-token DEPLOY_ENV=uat SNAPSHOT_TAG=v2026.08.15.2 \
  GITHUB_OUTPUT="${workdir}/invalid-preflight" bash "${preflight_script}" >"${workdir}/invalid.log" 2>&1; then
  echo "preflight unexpectedly accepted v* with uat" >&2
  exit 1
fi
grep -Fq "v* release tags require deploy_env=prod" "${workdir}/invalid.log"

echo "daily snapshot tag routing safeguards passed"
