#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq 'AGENT_PROXY_DOMAIN: ${{ matrix.host }}' "${workflow}" || {
  echo 'Agent Proxy deployment must derive the public domain from the per-host CMDB matrix entry' >&2
  exit 1
}

grep -Fq "AGENT_PROXY_LEGACY_DOMAIN: \${{ needs.provision.outputs.deployment_env == 'prod' && (matrix.host == format('agent-proxy-selfhost-{0}-jp.{1}', needs.provision.outputs.deployment_env, needs.provision.outputs.target_domain_base) || matrix.host == format('agent-proxy-selfhost-{0}.{1}', needs.provision.outputs.deployment_env, needs.provision.outputs.target_domain_base)) && 'tky-proxy.svc.plus' || '' }}" "${workflow}" || {
  echo 'The legacy production alias must be limited to the primary Tokyo host' >&2
  exit 1
}

if grep -Fq "AGENT_PROXY_DOMAIN: \${{ format('agent-proxy-selfhost-{0}.{1}'" "${workflow}"; then
  echo 'Agent Proxy deployment still contains the legacy single-domain hardcode' >&2
  exit 1
fi

echo "prod_agent_proxy_regional_domain_contract_test: PASS"
