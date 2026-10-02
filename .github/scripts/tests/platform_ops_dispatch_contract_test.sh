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
    GITHUB_WORKSPACE="${repo_root}" \
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

assert_in_output() {
  local output="$1" expected="$2"
  if ! grep -Fq "${expected}" <<<"${output}"; then
    echo "expected substring '${expected}' in route output:" >&2
    echo "${output}" >&2
    exit 1
  fi
}

deploy_output="$(run_route env INPUT_OPERATION=deploy INPUT_DNS_MODE=none)"
assert_contains "${deploy_output}" "run_infrastructure=true"
assert_contains "${deploy_output}" "run_application_deploy=true"
assert_contains "${deploy_output}" "terraform_action=apply"
assert_contains "${deploy_output}" "dns_mode=none"
assert_contains "${deploy_output}" "cloud_provider=akamai-cloud"
assert_contains "${deploy_output}" "provider_tree=akamai-cloud"
assert_contains "${deploy_output}" "resource_files_full=${repo_root}/gitops/resources/svc.plus/uat/akamai/web-saas.yaml"
if grep -Fq "config/resources/" <<<"${deploy_output}"; then
  echo "route still references the removed toolkit-local config/resources tree" >&2
  exit 1
fi

gcp_open_platform_output="$(run_route env INPUT_TARGET_DOMAINS=open-platform INPUT_CLOUD_PROVIDER=gcp-cloud INPUT_CLOUD_ACCOUNT=open-platform-prod INPUT_OPERATION=plan INPUT_DNS_MODE=none)"
assert_contains "${gcp_open_platform_output}" "resource_files_full=${repo_root}/gitops/resources/onwalk.net/uat/gcp/open-platform.yaml"

gcp_web_saas_output="$(run_route env INPUT_TARGET_DOMAINS=web-saas INPUT_CLOUD_PROVIDER=gcp-cloud INPUT_CLOUD_ACCOUNT=xworktech INPUT_OPERATION=plan INPUT_DNS_MODE=none)"
assert_contains "${gcp_web_saas_output}" "resource_files_full=${repo_root}/gitops/resources/onwalk.net/uat/gcp/web-saas.yaml"

if run_route env INPUT_TARGET_DOMAINS=all INPUT_CLOUD_PROVIDER=akamai-cloud INPUT_CLOUD_ACCOUNT=manbuzhe2026 INPUT_OPERATION=plan INPUT_DNS_MODE=none >/dev/null 2>&1; then
  echo "legacy direct Akamai target_domains=all unexpectedly bypassed Hybrid Orchestrator" >&2
  exit 1
fi

ai_spot_output="$(run_route env INPUT_TARGET_DOMAINS=ai-workspace INPUT_CLOUD_PROVIDER=gcp-cloud INPUT_CLOUD_ACCOUNT=xworktech INPUT_EXISTING_TARGET_HOST= INPUT_OPERATION=deploy INPUT_DNS_MODE=none)"
assert_contains "${ai_spot_output}" "reuse_existing_host=false"
assert_contains "${ai_spot_output}" "existing_target_host="
assert_contains "${ai_spot_output}" "terraform_action=apply"
assert_contains "${ai_spot_output}" "resource_files_full=${repo_root}/gitops/resources/svc.plus/uat/gcp/ai-workspace.yaml"

namespace_state_keys=()
for namespace in web-saas open-platform agent-proxy-jp agent-proxy-us agent-proxy-sg; do
  selected_domain="${namespace}"
  expected_domain="${namespace}"
  if [[ "${namespace}" == agent-proxy-* ]]; then
    expected_domain=agent-proxy
  fi
  routed="$(run_route env INPUT_TARGET_DOMAINS="${selected_domain}" INPUT_CLOUD_ACCOUNT=manbuzhe2026 INPUT_OPERATION=plan INPUT_DNS_MODE=none)"
  state_key="terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/${namespace}/terraform.tfstate"
  assert_contains "${routed}" "target_domains=${expected_domain}"
  assert_contains "${routed}" "terraform_namespace=${namespace}"
  assert_contains "${routed}" "terraform_workspace=uat-svc.plus-akamai-cloud-manbuzhe2026-${namespace}"
  assert_contains "${routed}" "terraform_project=svc.plus"
  assert_contains "${routed}" "state_key=${state_key}"
  assert_contains "${routed}" "terraform_workdir=envs/platform-ops-toolkit/${namespace}"
  assert_contains "${routed}" "env_dir=infra/iac_modules/terraform-hcl-standard/akamai-cloud/envs/platform-ops-toolkit/${namespace}"
  namespace_state_keys+=("${state_key}")
done
unique_state_key_count="$(printf '%s\n' "${namespace_state_keys[@]}" | sort -u | wc -l | tr -d ' ')"
if [[ "${unique_state_key_count}" -ne 5 || "${#namespace_state_keys[@]}" -ne 5 ]]; then
  echo "expected exactly five direct UAT Akamai namespace state keys; AI Workspace uses its GCP Spot state" >&2
  exit 1
fi

for aggregate in agent-proxy 'web-saas + agent-proxy'; do
  if run_route env INPUT_TARGET_DOMAINS="${aggregate}" INPUT_CLOUD_ACCOUNT=manbuzhe2026 INPUT_OPERATION=plan INPUT_DNS_MODE=none >/dev/null 2>&1; then
    echo "UAT Akamai aggregate target '${aggregate}' unexpectedly entered Terraform routing" >&2
    exit 1
  fi
done

matrix_workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
matrix_deploy_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_dispatch-selfhost-uat-namespace-matrix.sh"
grep -Fq 'Dispatch ordered UAT selfhost namespace deployments' "${matrix_workflow}"
grep -Fq 'CHILD_WORKFLOW: selfhost-orchestrator.yml' "${matrix_workflow}"
grep -Fq 'OBSERVABILITY_ENDPOINT: ${{ github.event.inputs.observability_endpoint || '\''https://observability.svc.plus'\'' }}' "${matrix_workflow}"
grep -Fq 'OBSERVE_EXPECTED_CODES: "200,404,401"' "${matrix_workflow}"
if grep -Fq 'OBSERVE_EXPECTED_CODES: "200,404,200"' "${matrix_workflow}"; then
  echo "Bridge health contract must not treat the protected unauthenticated endpoint as public" >&2
  exit 1
fi
grep -Fq 'contains(fromJSON('"'"'' "${matrix_workflow}"
grep -Fq '"ai-workspace","agent-proxy-jp","agent-proxy-us","agent-proxy-sg"' "${matrix_workflow}"
grep -Fq 'repository: ai-workspace-lab/xworkmate-bridge' "${matrix_workflow}"
grep -Fq 'path: xworkmate-bridge' "${matrix_workflow}"
grep -Fq 'owner: ai-workspace-lab' "${matrix_workflow}"
bash -n "${matrix_deploy_script}"
grep -Fq 'legacy Akamai-only UAT namespace dispatcher is disabled' "${matrix_deploy_script}"
grep -Fq 'id: gcp_oidc' "${matrix_workflow}"
grep -Fq 'TF_VAR_deploy_service_account=${{ steps.gcp_oidc.outputs.service_account }}' "${matrix_workflow}"
grep -Fq 'TF_VAR_workload_identity_provider=${{ steps.gcp_oidc.outputs.provider }}' "${matrix_workflow}"
python3 - "${matrix_workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
group = document["concurrency"]["group"]
if "github.event.inputs.target_domains" not in group:
    raise SystemExit("selfhost concurrency group must distinguish aggregate parent and namespace child runs")
PY

if run_route env INPUT_TARGET_DOMAINS=open-platform INPUT_CLOUD_ACCOUNT=manbuzhe2026 INPUT_OPERATION=destroy INPUT_DNS_MODE=none >/dev/null 2>&1; then
  echo "permanent UAT open-platform namespace unexpectedly accepted destroy" >&2
  exit 1
fi

for provider in aws-cloud gcp-cloud azure-cloud vultr-vps akamai-cloud; do
  provider_output="$(run_route env INPUT_CLOUD_PROVIDER="${provider}" INPUT_CLOUD_ACCOUNT=primary INPUT_OPERATION=plan INPUT_DNS_MODE=none)"
  # UAT uses the unified logical project segment for every Terraform
  # provider; the concrete account remains the next state-key component.
  provider_state_project=svc.plus
  assert_contains "${provider_output}" "cloud_provider=${provider}"
  assert_contains "${provider_output}" "provider_provisioner=terraform"
  assert_contains "${provider_output}" "state_key=terraform/uat/${provider_state_project}/${provider}/primary/web-saas/terraform.tfstate"
done

if run_route env INPUT_CLOUD_PROVIDER=ulighthost INPUT_OPERATION=plan INPUT_DNS_MODE=none >/dev/null 2>&1; then
  echo "existing-resource provider unexpectedly entered the Terraform route" >&2
  exit 1
fi

if run_route env INPUT_CLOUD_PROVIDER=not-a-provider INPUT_OPERATION=plan INPUT_DNS_MODE=none >/dev/null 2>&1; then
  echo "unregistered provider unexpectedly entered the Terraform route" >&2
  exit 1
fi

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
  python3 "${repo_root}/.github/scripts/gitops/validate_selfhost_contract.py" >"${contract_output}"; then
  echo "GitOps migration topology without an execution flag must be accepted" >&2
  cat "${contract_output}" >&2
  rm -f "${contract_output}"
  exit 1
fi
grep -Fq "async single-writer migration topology" "${contract_output}"
rm -f "${contract_output}"

prod_contract_fixture="$(mktemp)"
trap 'rm -f "${prod_contract_fixture}"' EXIT
python3 - "${contract_fixture}" "${prod_contract_fixture}" <<'PY'
import json
import sys

source, target = sys.argv[1:]
document = json.load(open(source, encoding="utf-8"))
document["metadata"]["environment"] = "prod"
document["spec"]["public_endpoints"]["agent-proxy"]["host"] = "agent-proxy-selfhost-prod-jp.svc.plus"
for endpoint in document["spec"]["public_endpoints"].values():
    endpoint["host"] = endpoint["host"].replace("-uat.onwalk.net", "-prod.svc.plus")
document["spec"]["runtime"]["routing"]["dns"]["canonical_records"] = {
    "console.svc.plus": "console-selfhost-prod.svc.plus",
    "accounts.svc.plus": "accounts-selfhost-prod.svc.plus",
}
document["spec"]["domains"] = {
    "console.svc.plus": {"selfhost": "console-selfhost-prod.svc.plus"},
    "accounts.svc.plus": {"selfhost": "accounts-selfhost-prod.svc.plus"},
}
json.dump(document, open(target, "w", encoding="utf-8"))
PY
prod_contract_output="$(mktemp)"
if ! GITOPS_ROUTING_CONFIG="${prod_contract_fixture}" \
  EXPECTED_ENV=prod \
  EXPECTED_TARGET_DOMAIN_BASE=svc.plus \
  python3 "${repo_root}/.github/scripts/gitops/validate_selfhost_contract.py" >"${prod_contract_output}"; then
  echo "Production GitOps topology with a regional Agent Proxy endpoint must be accepted" >&2
  cat "${prod_contract_output}" >&2
  rm -f "${prod_contract_output}"
  exit 1
fi
grep -Fq "async single-writer migration topology" "${prod_contract_output}"
rm -f "${prod_contract_output}"

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
