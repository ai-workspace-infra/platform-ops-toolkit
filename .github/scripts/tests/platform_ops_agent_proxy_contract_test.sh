#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

deployment_block="$(sed -n '/- name: Deploy native agent-proxy services/,/^  deploy_ai_workspace:/p' "${workflow}")"

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

assert_contains "-e agent_proxy_manage_source_checkout=true"
assert_contains "-e agent_proxy_build_on_target=true"
assert_contains "-e agent_proxy_wait_for_runtime_config=false"

assert_absent "agent_svc_plus_manage_source_checkout"
assert_absent "agent_svc_plus_build_on_target"
assert_absent "agent_svc_plus_wait_for_runtime_config"

echo "platform_ops_agent_proxy_contract_test: PASS"
