#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
route_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_route-ref-to-an-explicit-profile.sh"

run_push_route() {
  local ref="$1" output
  output="$(mktemp)"
  if ! GITHUB_EVENT_NAME=push \
    GITHUB_REF="${ref}" \
    GITHUB_REF_NAME="${ref##*/}" \
    INPUT_OFFLINE_MODE=off \
    INPUT_SOURCE_HOST=install.svc.plus \
    INPUT_SOURCE_DOMAIN_BASE=svc.plus \
    INPUT_TARGET_DOMAIN_BASE=onwalk.net \
    INPUT_DNS_MODE=none \
    GITHUB_OUTPUT="${output}" \
    "${route_script}"; then
    rm -f "${output}"
    return 1
  fi
  cat "${output}"
  rm -f "${output}"
}

assert_output() {
  local output="$1" expected="$2"
  if ! grep -Fqx "${expected}" <<<"${output}"; then
    echo "expected '${expected}', got:" >&2
    echo "${output}" >&2
    exit 1
  fi
}

assert_rejected() {
  local ref="$1"
  if run_push_route "${ref}" >/dev/null 2>&1; then
    echo "${ref} unexpectedly entered the production route" >&2
    exit 1
  fi
}

tag_output="$(run_push_route refs/tags/v2026.08.15)"
assert_output "${tag_output}" "deployment_env=prod"
assert_output "${tag_output}" "resource_file=prod/web-saas"
assert_output "${tag_output}" "deploy_tag=v2026.08.15"

release_output="$(run_push_route refs/heads/release/v2026.08)"
assert_output "${release_output}" "deployment_env=prod"
assert_output "${release_output}" "resource_file=prod/web-saas"
assert_output "${release_output}" "deploy_tag=v2026.08"

main_output="$(run_push_route refs/heads/main)"
assert_output "${main_output}" "deployment_env=uat"
assert_output "${main_output}" "deploy_tag="

other_release_output="$(run_push_route refs/heads/release/2026.08)"
assert_output "${other_release_output}" "deployment_env=uat"
assert_rejected refs/tags/daily-build-2026.08.15
assert_rejected refs/tags/uat-daily-build-2026.08.15-r1

dispatch_output_file="$(mktemp)"
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF=refs/heads/release/v2026.08 \
INPUT_VAULT_ENV_PATH=prod \
INPUT_TARGET_DOMAINS=web-saas \
INPUT_OPERATION=plan \
INPUT_OFFLINE_MODE=off \
INPUT_SOURCE_HOST=install.svc.plus \
INPUT_SOURCE_DOMAIN_BASE=svc.plus \
INPUT_TARGET_DOMAIN_BASE=onwalk.net \
INPUT_DNS_MODE=none \
GITHUB_OUTPUT="${dispatch_output_file}" \
"${route_script}"
dispatch_output="$(cat "${dispatch_output_file}")"
rm -f "${dispatch_output_file}"
assert_output "${dispatch_output}" "deployment_env=prod"

dispatch_rejected_output="$(mktemp)"
if GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_REF=refs/heads/main \
  INPUT_VAULT_ENV_PATH=prod \
  INPUT_TARGET_DOMAINS=web-saas \
  INPUT_OPERATION=plan \
  INPUT_OFFLINE_MODE=off \
  INPUT_SOURCE_HOST=install.svc.plus \
  INPUT_SOURCE_DOMAIN_BASE=svc.plus \
  INPUT_TARGET_DOMAIN_BASE=onwalk.net \
  INPUT_DNS_MODE=none \
  GITHUB_OUTPUT="${dispatch_rejected_output}" \
  "${route_script}" >/dev/null 2>&1; then
  rm -f "${dispatch_rejected_output}"
  echo "workflow_dispatch prod from main unexpectedly succeeded" >&2
  exit 1
fi
rm -f "${dispatch_rejected_output}"

echo "platform_ops_prod_ref_scope_test: PASS"
