#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq 'needs: [provision, deploy_base, deploy_agent_proxy, deploy_agent_proxy_non_iac]' "${workflow}"
grep -Fq 'needs.deploy_agent_proxy_non_iac.result == '\''success'\''' "${workflow}"
grep -Fq "needs.provision.outputs.hosts_agent_proxy_non_iac == '[]'" "${workflow}"
grep -Fq 'needs.provision.outputs.hosts_agent_proxy_iac' "${workflow}"
grep -Fq 'needs.provision.outputs.hosts_agent_proxy_non_iac' "${workflow}"
non_iac_block="$(sed -n '/^  deploy_agent_proxy_non_iac:/,/^  deploy_ai_workspace:/p' "${workflow}")"
grep -Fq 'Deploy Observability Agent for non-IaC Agent Proxy' <<<"${non_iac_block}"
grep -Fq 'deploy_observability_agent.yml' <<<"${non_iac_block}"
grep -Fq 'VECTOR_BILLING_INGEST_ENABLED: '\''true'\''' <<<"${non_iac_block}"
grep -Fq 'VECTOR_SNAPSHOT_URL: http://127.0.0.1:8686' <<<"${non_iac_block}"

echo "platform_ops_monitor_agent_matrix_contract_test: PASS"
