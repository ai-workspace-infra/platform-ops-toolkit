#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"
runner="${repo_root}/.github/scripts/xconnect-lab/run.sh"
topology_policy="${repo_root}/.github/scripts/xconnect-lab/validate-topology.jq"
gateway="${repo_root}/.github/scripts/xconnect-lab/gateway.sh"
role="github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab"

bash -n "${roles}"

grep -Fq "XCONNECT_CLOUD_LAB_ROLE=\"${role}\"" "${roles}"
grep -Fq '"job_workflow_ref": "${WF_PREFIX}/xconnect-zero-cloud.yaml@refs/heads/main"' "${roles}"
grep -Fq 'XCONNECT_CLOUD_LAB_POLICY="github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab"' "${roles}"
grep -Fq '"token_policies": ["${XCONNECT_CLOUD_LAB_POLICY}"]' "${roles}"
grep -Fq 'path "kv/data/prod/ulighthost-xconnect/TW-XConnect.onwalk.net"' "${roles}"
if grep -Fq 'path "kv/data/prod/*"' "${roles}"; then
  echo "XConnect cloud lab must not receive broad production access" >&2
  exit 1
fi
grep -Fq 'path "kv/data/uat/xconnect-one"' "${roles}"
grep -Fq 'path "kv/data/CICD/observability"' "${roles}"

if grep -Fq '"${WF_PREFIX}/xconnect-cloud-lab.yml@*"' "${roles}"; then
  echo "XConnect cloud lab must use its dedicated main-only role, not the general workflow allowlist" >&2
  exit 1
fi

grep -Fq "XCONNECT_VAULT_ROLE: ${role}" "${workflow}"
[[ $(grep -Fc 'role: ${{ env.XCONNECT_VAULT_ROLE }}' "${workflow}") -eq 1 ]]
if grep -Eq '^  schedule:' "${workflow}"; then
  echo "XConnect cloud lab must be released from an immutable UAT snapshot, not a schedule" >&2
  exit 1
fi
grep -Fq -- '-f "$ROOT/.github/scripts/xconnect-lab/validate-topology.jq"' "${runner}"
grep -Fq ".spec.vault.role == \"${role}\"" "${topology_policy}"

grep -Fq 'kv/data/CICD/uat TF_STATE_ENDPOINT' "${workflow}"
grep -Fq 'kv/data/uat/xconnect-one ZERO_SERVICE_TOKEN' "${workflow}"
grep -Fq 'kv/data/uat/xconnect-one ZERO_OWNER_EMAIL' "${workflow}"
grep -Fq 'gitops/vpn-overlay/uat/xconnect-lab.json' "${runner}"
grep -Fq 'xconnect-gateway init' "${gateway}"

echo "XConnect UAT cloud-lab Vault role contract is pinned to the workflow on main."
