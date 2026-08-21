#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
route="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_route-ref-to-an-explicit-profile.sh"
resolver="${repo_root}/.github/scripts/platform-ops/deploy/platform-ops_deploy_agent_proxy_resolve-controller-ip.sh"
summary="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_deployment-summary.sh"

grep -Fq 'agent_controller_url:' "${workflow}"
grep -Fq 'INPUT_AGENT_CONTROLLER_URL:' "${workflow}"
grep -Fq 'agent_controller_url:     ${{ steps.route.outputs.agent_controller_url }}' "${workflow}"
grep -Fq 'AGENT_CONTROLLER_URL: ${{ needs.provision.outputs.agent_controller_url }}' "${workflow}"
grep -Fq 'ACCOUNTS_BASE_URL: ${{ needs.provision.outputs.agent_controller_url }}' "${workflow}"
grep -Fq 'agent_controller_url="${INPUT_AGENT_CONTROLLER_URL:-}"' "${route}"
grep -Fq 'getent ahostsv4' "${resolver}"
grep -Fq 'Agent Proxy controller:' "${summary}"

route_output="$(mktemp)"
trap 'rm -f "${route_output}"' EXIT
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REF=refs/heads/main \
INPUT_VAULT_ENV_PATH=uat \
INPUT_TARGET_DOMAINS=agent-proxy \
INPUT_OPERATION=deploy \
INPUT_DEPLOY_TAG=uat-daily-build-2026.08.21-r5 \
INPUT_CLOUD_PROVIDER=vultr-vps \
INPUT_OFFLINE_MODE=off \
INPUT_SOURCE_HOST=console.svc.plus \
INPUT_SOURCE_DOMAIN_BASE=svc.plus \
INPUT_TARGET_DOMAIN_BASE=onwalk.net \
INPUT_DNS_MODE=uat-records \
INPUT_AGENT_CONTROLLER_URL=https://accounts-serverless-uat.onwalk.net \
GITHUB_OUTPUT="${route_output}" \
"${route}" >/dev/null
grep -Fqx 'agent_controller_url=https://accounts-serverless-uat.onwalk.net' "${route_output}"

echo "platform_ops_agent_proxy_controller_contract_test: PASS"
