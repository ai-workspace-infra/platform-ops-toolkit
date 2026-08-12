#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
route_script="${repo_root}/.github/scripts/platform-ops_provision_route-ref-to-an-explicit-profile.sh"
xray_script="${repo_root}/.github/scripts/platform-ops_deploy_resolve-xray-exporter-image.sh"

run_route() {
  local output
  output="$(mktemp)"
  if ! GITHUB_EVENT_NAME=workflow_dispatch \
    INPUT_VAULT_ENV_PATH=uat \
    INPUT_TARGET_DOMAINS=web-saas \
    INPUT_DEPLOY_TAG=uat-daily-build-2026.08.12-r14 \
    INPUT_SOURCE_HOST=install.svc.plus \
    INPUT_SOURCE_DOMAIN_BASE=svc.plus \
    INPUT_TARGET_DOMAIN_BASE=onwalk.net \
    INPUT_OFFLINE_MODE=off \
    INPUT_CONFIRM_DNS_SWITCH=false \
    GITHUB_OUTPUT="${output}" \
    "$@" "${route_script}"; then
    rm -f "${output}"
    return 1
  fi
  cat "${output}"
  rm -f "${output}"
}

assert_contains() {
  local output="$1" expected="$2"
  if ! grep -Fqx "${expected}" <<<"${output}"; then
    echo "expected '${expected}' in route output:" >&2
    echo "${output}" >&2
    exit 1
  fi
}

deploy_output="$(run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=none)"
assert_contains "${deploy_output}" "run_infrastructure=true"
assert_contains "${deploy_output}" "run_application_deploy=true"
assert_contains "${deploy_output}" "terraform_action=apply"

source_ref_output="$(run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=none INPUT_SOURCE_REF=uat-daily-build-2026.08.12-r14)"
assert_contains "${source_ref_output}" "infra_ref=uat-daily-build-2026.08.12-r14"
assert_contains "${source_ref_output}" "playbooks_ref=uat-daily-build-2026.08.12-r14"
assert_contains "${source_ref_output}" "gitops_ref=uat-daily-build-2026.08.12-r14"
assert_contains "${source_ref_output}" "toolkit_ref=uat-daily-build-2026.08.12-r14"

plan_output="$(run_route env INPUT_OPERATION=plan INPUT_DNS_MODE=none)"
assert_contains "${plan_output}" "run_infrastructure=true"
assert_contains "${plan_output}" "run_application_deploy=false"
assert_contains "${plan_output}" "terraform_action=plan"

uat_dns_output="$(run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=uat-records)"
assert_contains "${uat_dns_output}" "uat_dns_update=true"
assert_contains "${uat_dns_output}" "confirm_dns_switch=false"

if run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=prod-cutover >/dev/null 2>&1; then
  echo "prod-cutover without confirmation unexpectedly succeeded" >&2
  exit 1
fi

xray_output="$(mktemp)"
GITHUB_OUTPUT="${xray_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=uat-daily-build-2026.08.12-r14 \
  INPUT_XRAY_EXPORTER_IMAGE='example/xray-exporter@v1.2.3' "${xray_script}"
assert_contains "$(cat "${xray_output}")" "repository=example/xray-exporter"
assert_contains "$(cat "${xray_output}")" "version=v1.2.3"
rm -f "${xray_output}"

default_xray_output="$(mktemp)"
GITHUB_OUTPUT="${default_xray_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=uat-daily-build-2026.08.12-r14 \
  "${xray_script}"
assert_contains "$(cat "${default_xray_output}")" "repository=ai-workspace-xstream/xray-exporter"
assert_contains "$(cat "${default_xray_output}")" "version=uat-daily-build-2026.08.12-r14"
rm -f "${default_xray_output}"

invalid_output="$(mktemp)"
if GITHUB_OUTPUT="${invalid_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=uat-daily-build-2026.08.12-r14 \
  INPUT_XRAY_EXPORTER_IMAGE='missing-separator' "${xray_script}" >/dev/null 2>&1; then
  echo "invalid Xray exporter image unexpectedly succeeded" >&2
  exit 1
fi
rm -f "${invalid_output}"

echo "platform_ops_dispatch_contract_test: PASS"
