#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"
workflow="${repo_root}/.github/workflows/xconnect-cloud-lab.yml"
runner="${repo_root}/.github/scripts/xconnect-lab/run.sh"
gateway="${repo_root}/.github/scripts/xconnect-lab/gateway.sh"
role="github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab"

bash -n "${roles}"

grep -Fq "XCONNECT_CLOUD_LAB_ROLE=\"${role}\"" "${roles}"
grep -Fq '"job_workflow_ref": "${WF_PREFIX}/xconnect-cloud-lab.yml@refs/heads/main"' "${roles}"
grep -Fq '"token_policies": ["github-actions-platform-ops-toolkit-uat"]' "${roles}"

if grep -Fq '"${WF_PREFIX}/xconnect-cloud-lab.yml@*"' "${roles}"; then
  echo "XConnect cloud lab must use its dedicated main-only role, not the general workflow allowlist" >&2
  exit 1
fi

grep -Fq "XCONNECT_VAULT_ROLE: ${role}" "${workflow}"
[[ $(grep -Fc 'role: ${{ env.XCONNECT_VAULT_ROLE }}' "${workflow}") -eq 2 ]]
grep -Fq ".spec.vault.role == \"${role}\"" "${runner}"

grep -Fq 'kv/data/CICD/uat TF_STATE_ENDPOINT' "${workflow}"
grep -Fq 'kv/data/uat/xconnect-one ZERO_SERVICE_TOKEN' "${workflow}"
grep -Fq 'kv/data/uat/xconnect-one ZERO_OWNER_EMAIL' "${workflow}"
grep -Fq 'gitops/topology/uat/xconnect-lab.json' "${runner}"
grep -Fq 'xconnect-gateway init' "${gateway}"

echo "XConnect UAT cloud-lab Vault role contract is pinned to the workflow on main."
