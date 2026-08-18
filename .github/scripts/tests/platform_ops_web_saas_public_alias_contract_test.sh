#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq "WEB_SAAS_CONSOLE_DOMAIN:           \${{ format('console-selfhost-{0}.{1}', needs.provision.outputs.deployment_env, needs.provision.outputs.target_domain_base) }}" "${workflow}"
grep -Fq "WEB_SAAS_ACCOUNTS_DOMAIN:          \${{ format('accounts-selfhost-{0}.{1}', needs.provision.outputs.deployment_env, needs.provision.outputs.target_domain_base) }}" "${workflow}"

echo "platform_ops_web_saas_vps_alias_contract_test: PASS"
