#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq "contains(needs.provision.outputs.target_domains, 'agent-proxy')" "${workflow}" || {
  echo "agent-proxy-only deployments must restore the shared Vault TLS certificate" >&2
  exit 1
}

deployment_block="$(sed -n '/- name: Deploy native agent-proxy services/,/^  deploy_ai_workspace:/p' "${workflow}")"
monitor_block="$(sed -n '/^  deploy_monitor_agent:/,/^  trigger_data_migration:/p' "${workflow}")"

assert_contains() {
  local expected="$1"
  if ! grep -Fq -- "${expected}" <<<"${deployment_block}"; then
    echo "expected Agent Proxy deployment block to contain: ${expected}" >&2
    exit 1
  fi
}

assert_absent() {
  local unexpected="$1"
  if grep -Fq -- "${unexpected}" <<<"${deployment_block}"; then
    echo "unexpected legacy Agent Proxy variable in deployment block: ${unexpected}" >&2
    exit 1
  fi
}

assert_monitor_contains() {
  local expected="$1"
  if ! grep -Fq -- "${expected}" <<<"${monitor_block}"; then
    echo "expected Monitor Agent block to contain: ${expected}" >&2
    exit 1
  fi
}

assert_contains "-e agent_proxy_manage_source_checkout=true"
assert_contains "-e agent_proxy_build_on_target=true"
assert_contains "-e agent_proxy_wait_for_runtime_config=false"
assert_contains 'AGENT_BILLING_ENABLED: "false"'
assert_contains "VECTOR_SNAPSHOT_URL: http://127.0.0.1:8686"
assert_contains "AGENT_PROXY_DOMAIN: \${{ format('agent-proxy-selfhost-{0}.{1}', needs.provision.outputs.deployment_env, needs.provision.outputs.target_domain_base) }}"
assert_absent "agent-proxy-vps-"

assert_absent "agent_svc_plus_manage_source_checkout"
assert_absent "agent_svc_plus_build_on_target"
assert_absent "agent_svc_plus_wait_for_runtime_config"

assert_monitor_contains "needs: [provision, deploy_base, deploy_agent_proxy]"
assert_monitor_contains "always() && !cancelled()"
assert_monitor_contains "needs.deploy_agent_proxy.result == 'success'"
assert_monitor_contains "Verify Xray to Billing ingest chain"
assert_monitor_contains 'VECTOR_BILLING_INGEST_URL: ${{ format('\''{0}/v1/ingest/snapshots'\'', needs.provision.outputs.billing_service_base_url) }}'
assert_monitor_contains 'VECTOR_BILLING_INGEST_ENABLED: ${{ contains(fromJSON('
assert_monitor_contains "needs.provision.outputs.target_domains) && 'true' || 'false' }}"
assert_monitor_contains 'VECTOR_SNAPSHOT_URL: ${{ contains(fromJSON('
assert_monitor_contains "needs.provision.outputs.target_domains) && 'http://127.0.0.1:8686' || '' }}"

echo "platform_ops_agent_proxy_contract_test: PASS"
