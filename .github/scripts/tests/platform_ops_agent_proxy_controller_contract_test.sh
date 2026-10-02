#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${repo_root}"
route=".github/scripts/platform-ops/provision/platform-ops_provision_route-ref-to-an-explicit-profile.sh"
resolver=".github/scripts/platform-ops/provision/platform-ops_provision_resolve-agent-proxy-service-origins.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
route_env() {
  env GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF="$(if [[ "$1" == prod ]]; then echo refs/tags/v1.2.3; else echo refs/heads/main; fi)" \
    INPUT_VAULT_ENV_PATH="$1" INPUT_TARGET_DOMAINS=agent-proxy \
    INPUT_OPERATION=deploy INPUT_DEPLOY_TAG="$(if [[ "$1" == prod ]]; then echo v1.2.3; else echo daily-build-2026.10.02-r1; fi)" \
    INPUT_CLOUD_PROVIDER=vultr-vps INPUT_OFFLINE_MODE=off \
    INPUT_SOURCE_HOST=console.svc.plus INPUT_SOURCE_DOMAIN_BASE=svc.plus \
    INPUT_TARGET_DOMAIN_BASE="$2" INPUT_DNS_MODE=none \
    INPUT_AGENT_CONTROLLER_URL="${3:-}" GITHUB_OUTPUT="${workdir}/route" "${route}"
}
route_env uat onwalk.net >/dev/null
grep -Fqx 'agent_controller_url=https://accounts-uat.onwalk.net' "${workdir}/route"
grep -Fqx 'billing_service_base_url=https://billing-uat.onwalk.net' "${workdir}/route"
: >"${workdir}/route"
route_env prod svc.plus >/dev/null
grep -Fqx 'agent_controller_url=https://accounts.svc.plus' "${workdir}/route"
grep -Fqx 'billing_service_base_url=https://billing.svc.plus' "${workdir}/route"
if route_env uat onwalk.net https://accounts.svc.plus >/dev/null 2>&1; then
  echo 'Cross-environment controller was accepted' >&2; exit 1
fi
cat >"${workdir}/topology.yaml" <<'YAML'
kind: EdgeRoutingConfig
metadata:
  environment: uat
spec:
  domains:
    accounts-uat.onwalk.net:
      selfhost: accounts-selfhost-uat.onwalk.net
    billing-uat.onwalk.net:
      selfhost: billing-selfhost-uat.onwalk.net
  serverless:
    accounts_host: accounts-serverless-uat.onwalk.net
    cloud_run:
      accounts: https://uat-accounts-123.asia-northeast1.run.app
      billing_service: https://uat-billing-service-123.asia-northeast1.run.app
YAML
resolve() {
  DEPLOYMENT_ENV="$1" AGENT_CONTROLLER_URL="$2" \
    BILLING_SERVICE_BASE_URL=https://billing-uat.onwalk.net \
    GITOPS_SERVERLESS_ROUTING_YAML="${workdir}/topology.yaml" \
    GITHUB_OUTPUT="${workdir}/origins" "${resolver}"
}
resolve uat https://accounts-uat.onwalk.net >/dev/null
grep -Fqx 'accounts_service_base_url=https://uat-accounts-123.asia-northeast1.run.app' "${workdir}/origins"
grep -Fqx 'billing_service_base_url=https://uat-billing-service-123.asia-northeast1.run.app' "${workdir}/origins"
: >"${workdir}/origins"
resolve uat https://accounts-selfhost-uat.onwalk.net >/dev/null
grep -Fqx 'billing_service_base_url=https://billing-selfhost-uat.onwalk.net' "${workdir}/origins"
if resolve prod https://accounts.svc.plus >/dev/null 2>&1; then
  echo 'Cross-environment topology was accepted' >&2; exit 1
fi
sed -i.bak 's/uat-billing-service/prod-billing-service/' "${workdir}/topology.yaml"
if resolve uat https://accounts-uat.onwalk.net >/dev/null 2>&1; then
  echo 'Production Billing origin was accepted for UAT' >&2; exit 1
fi
echo 'platform_ops_agent_proxy_controller_contract_test: PASS'
