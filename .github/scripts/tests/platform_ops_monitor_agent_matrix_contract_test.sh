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
# The non-IaC observability step interpolates OBSERVABILITY_ENDPOINT. Without a
# job-level definition it expands to an empty string and Vector writes to a
# relative URL, which leaves ph-xconnect.svc.plus with no metrics at all.
grep -Fq "OBSERVABILITY_ENDPOINT: \${{ github.event.inputs.observability_endpoint || 'https://observability.svc.plus' }}" <<<"${non_iac_block}"
grep -Fq 'Validate central observability endpoint for non-IaC node' <<<"${non_iac_block}"

monitor_block="$(sed -n '/^  deploy_monitor_agent:/,/^  trigger_data_migration:/p' "${workflow}")"
grep -Fq 'Validate central observability endpoint' <<<"${monitor_block}"
grep -Fq 'platform-ops_deploy_monitor_agent.sh' <<<"${monitor_block}"
grep -Fq "OBSERVABILITY_ENDPOINT: \${{ github.event.inputs.observability_endpoint || 'https://observability.svc.plus' }}" <<<"${monitor_block}"

echo "platform_ops_monitor_agent_matrix_contract_test: PASS"
