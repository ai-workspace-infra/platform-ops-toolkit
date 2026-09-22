#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
dispatch_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_dispatch-xconnect-uat.sh"
summary_script="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_deployment-summary.sh"

for input in xconnect_gateway_ref; do
  grep -Fq "      ${input}:" "${workflow}" || {
    echo "selfhost workflow is missing configurable XConnect input: ${input}" >&2
    exit 1
  }
done

grep -Fq 'deploy_xconnect_zero_uat:' "${workflow}"
grep -Fq 'needs: [provision, provision_akamai_uat_namespace_matrix]' "${workflow}"
grep -Fq "needs.provision.outputs.target_domains == 'all'" "${workflow}"
grep -Fq "needs.provision.outputs.deployment_env == 'uat'" "${workflow}"
grep -Fq 'XCONNECT_GATEWAY_REF:' "${workflow}"
grep -Fq 'run: .github/scripts/platform-ops/provision/platform-ops_provision_dispatch-xconnect-uat.sh' "${workflow}"
grep -Fq 'XCONNECT_ZERO_UAT_RESULT:' "${workflow}"
grep -Fq 'XCONNECT_ZERO_UAT_RESULT' "${summary_script}"
grep -Fq 'UAT target_domains=all requires a successful XConnect Zero UAT run' "${summary_script}"

grep -Fq 'deployment_profile:"existing-one"' "${dispatch_script}"
grep -Fq 'mode:"apply"' "${dispatch_script}"
grep -Fq 'gateway_provider:"external"' "${dispatch_script}"
grep -Fq 'external_gateway_server_name:$gateway_ref' "${dispatch_script}"
grep -Fq 'gateway_vault_key:$gateway_ref' "${dispatch_script}"
grep -Fq 'matrix_node_filter:"all"' "${dispatch_script}"
grep -Fq 'gh run watch "${run_id}"' "${dispatch_script}"

if grep -Fq 'mode:"cleanup"' "${dispatch_script}"; then
  echo 'XConnect UAT aggregate adapter must never dispatch cleanup' >&2
  exit 1
fi

bash -n "${dispatch_script}"
echo "selfhost_xconnect_uat_contract_test: PASS"
