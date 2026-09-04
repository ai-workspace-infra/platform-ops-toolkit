#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
route_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_route-ref-to-an-explicit-profile.sh"
xray_script="${repo_root}/.github/scripts/platform-ops/deploy/platform-ops_deploy_resolve-xray-exporter-image.sh"

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
assert_contains "${deploy_output}" "dns_mode=none"

source_ref_output="$(run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=none INPUT_SOURCE_REF=uat-daily-build-2026.08.12-r14)"
assert_contains "${source_ref_output}" "infra_ref=uat-daily-build-2026.08.12-r14"
assert_contains "${source_ref_output}" "playbooks_ref=uat-daily-build-2026.08.12-r14"
assert_contains "${source_ref_output}" "gitops_ref=uat-daily-build-2026.08.12-r14"
assert_contains "${source_ref_output}" "toolkit_ref=uat-daily-build-2026.08.12-r14"

plan_output="$(run_route env INPUT_OPERATION=plan INPUT_DNS_MODE=none)"
assert_contains "${plan_output}" "run_infrastructure=true"
assert_contains "${plan_output}" "run_application_deploy=false"
assert_contains "${plan_output}" "terraform_action=plan"

migrate_output="$(run_route env INPUT_OPERATION=migrate INPUT_DNS_MODE=none)"
assert_contains "${migrate_output}" "run_infrastructure=false"
assert_contains "${migrate_output}" "run_application_deploy=false"
assert_contains "${migrate_output}" "terraform_action=none"
assert_contains "${migrate_output}" "toolkit_action=migrate"

deploy_migrate_output="$(run_route env INPUT_OPERATION=deploy+migrate INPUT_DNS_MODE=none)"
assert_contains "${deploy_migrate_output}" "run_infrastructure=true"
assert_contains "${deploy_migrate_output}" "run_application_deploy=true"
assert_contains "${deploy_migrate_output}" "terraform_action=apply"
assert_contains "${deploy_migrate_output}" "toolkit_action=deploy+migrate"

destroy_output="$(run_route env INPUT_OPERATION=destroy INPUT_DNS_MODE=uat-records)"
assert_contains "${destroy_output}" "run_infrastructure=true"
assert_contains "${destroy_output}" "run_application_deploy=false"
assert_contains "${destroy_output}" "terraform_action=destroy"
assert_contains "${destroy_output}" "dns_mode=none"
assert_contains "${destroy_output}" "deploy_tag="

prod_destroy_error="$(mktemp)"
if run_route env GITHUB_REF=refs/heads/release/v2026.08 INPUT_VAULT_ENV_PATH=prod INPUT_OPERATION=destroy INPUT_DNS_MODE=prod-cutover >"${prod_destroy_error}" 2>&1; then
  rm -f "${prod_destroy_error}"
  echo "production destroy unexpectedly entered the deployment route" >&2
  exit 1
fi
grep -Fq "Production infrastructure is deletion-protected" "${prod_destroy_error}"
rm -f "${prod_destroy_error}"

contract_fixture="${repo_root}/.github/scripts/tests/fixtures/selfhost-routing-migration-topology.json"
contract_output="$(mktemp)"
if ! GITOPS_ROUTING_CONFIG="${contract_fixture}" \
  EXPECTED_ENV=uat \
  EXPECTED_TARGET_DOMAIN_BASE=onwalk.net \
  python3 "${repo_root}/.github/scripts/platform-ops/routing/validate_selfhost_contract.py" >"${contract_output}"; then
  echo "GitOps migration topology without an execution flag must be accepted" >&2
  cat "${contract_output}" >&2
  rm -f "${contract_output}"
  exit 1
fi
grep -Fq "async single-writer migration topology" "${contract_output}"
rm -f "${contract_output}"

uat_dns_output="$(run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=uat-records)"
assert_contains "${uat_dns_output}" "dns_mode=uat-records"

uat_stable_error="$(mktemp)"
if run_route env INPUT_OPERATION=deploy INPUT_DEPLOY_TAG=v2026.08.15.3 INPUT_DNS_MODE=none >"${uat_stable_error}" 2>&1; then
  rm -f "${uat_stable_error}"
  echo "UAT stable release tag unexpectedly entered the deployment route" >&2
  exit 1
fi
grep -Fq "v* release tags are PROD-only" "${uat_stable_error}"
rm -f "${uat_stable_error}"

if run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=prod-cutover >/dev/null 2>&1; then
  echo "prod-cutover without production environment unexpectedly succeeded" >&2
  exit 1
fi

prod_dns_output="$(run_route env GITHUB_REF=refs/heads/release/v2026.08 INPUT_VAULT_ENV_PATH=prod INPUT_OPERATION=deploy INPUT_DEPLOY_TAG=v2026.08 INPUT_DNS_MODE=prod-cutover)"
assert_contains "${prod_dns_output}" "dns_mode=prod-cutover"

prod_daily_error="$(mktemp)"
if run_route env GITHUB_REF=refs/heads/release/v2026.08 INPUT_VAULT_ENV_PATH=prod INPUT_OPERATION=deploy INPUT_DEPLOY_TAG=uat-daily-build-2026.08.15-r1 INPUT_DNS_MODE=none >"${prod_daily_error}" 2>&1; then
  rm -f "${prod_daily_error}"
  echo "PROD daily snapshot tag unexpectedly entered the deployment route" >&2
  exit 1
fi
grep -Fq "PROD application deployments accept only v* deploy tags" "${prod_daily_error}"
rm -f "${prod_daily_error}"

xray_output="$(mktemp)"
GITHUB_OUTPUT="${xray_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=uat-daily-build-2026.08.12-r14 \
  INPUT_XRAY_EXPORTER_IMAGE='example/xray-exporter@v1.2.3' "${xray_script}"
assert_contains "$(cat "${xray_output}")" "repository=example/xray-exporter"
assert_contains "$(cat "${xray_output}")" "version=v1.2.3"
rm -f "${xray_output}"

default_xray_output="$(mktemp)"
GITHUB_OUTPUT="${default_xray_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=uat-daily-build-2026.08.15-r1 \
  XRAY_EXPORTER_RELEASES_JSON='[{"tag_name":"uat-daily-build-2026.08.14-r1"},{"tag_name":"uat-daily-build-2026.08.14-r2"}]' \
  "${xray_script}"
assert_contains "$(cat "${default_xray_output}")" "repository=ai-workspace-xstream/xray-exporter"
assert_contains "$(cat "${default_xray_output}")" "version=uat-daily-build-2026.08.14-r2"
rm -f "${default_xray_output}"

daily_alias_output="$(mktemp)"
GITHUB_OUTPUT="${daily_alias_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=daily-build-2026.08.14 \
  XRAY_EXPORTER_RELEASES_JSON='[{"tag_name":"uat-daily-build-2026.08.14-r1"},{"tag_name":"uat-daily-build-2026.08.14-r2"}]' \
  "${xray_script}"
assert_contains "$(cat "${daily_alias_output}")" "repository=ai-workspace-xstream/xray-exporter"
assert_contains "$(cat "${daily_alias_output}")" "version=uat-daily-build-2026.08.14-r2"
rm -f "${daily_alias_output}"

daily_retry_output="$(mktemp)"
GITHUB_OUTPUT="${daily_retry_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=daily-build-2026.08.15-r3 \
  XRAY_EXPORTER_RELEASES_JSON='[{"tag_name":"daily-build-2026.08.15-r3","assets":[{"name":"xray-exporter-linux-amd64"},{"name":"xray-exporter-linux-arm64"}]}]' \
  "${xray_script}"
assert_contains "$(cat "${daily_retry_output}")" "repository=ai-workspace-xstream/xray-exporter"
assert_contains "$(cat "${daily_retry_output}")" "version=daily-build-2026.08.15-r3"
rm -f "${daily_retry_output}"

prod_xray_output="$(mktemp)"
GITHUB_OUTPUT="${prod_xray_output}" DEPLOYMENT_ENV=prod DEPLOY_TAG=v2026.09.04-r6 \
  XRAY_EXPORTER_RELEASES_JSON='[{"tag_name":"uat-daily-build-2026.09.04-r10","assets":[{"name":"xray-exporter-linux-amd64"},{"name":"xray-exporter-linux-arm64"}]},{"tag_name":"daily-build-2026.09.03-r4","assets":[{"name":"xray-exporter-linux-amd64"},{"name":"xray-exporter-linux-arm64"}]},{"tag_name":"daily-build-2026.09.04-r1","assets":[{"name":"xray-exporter-linux-amd64"},{"name":"xray-exporter-linux-arm64"}]}]' \
  "${xray_script}"
assert_contains "$(cat "${prod_xray_output}")" "repository=ai-workspace-xstream/xray-exporter"
assert_contains "$(cat "${prod_xray_output}")" "version=daily-build-2026.09.04-r1"
rm -f "${prod_xray_output}"

invalid_output="$(mktemp)"
if GITHUB_OUTPUT="${invalid_output}" DEPLOYMENT_ENV=uat DEPLOY_TAG=uat-daily-build-2026.08.12-r14 \
  INPUT_XRAY_EXPORTER_IMAGE='missing-separator' "${xray_script}" >/dev/null 2>&1; then
  echo "invalid Xray exporter image unexpectedly succeeded" >&2
  exit 1
fi
rm -f "${invalid_output}"

echo "platform_ops_dispatch_contract_test: PASS"
