#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
roles="${repo_root}/scripts/create_vault_service_repo_roles.sh"
cloud_lab_policy="${repo_root}/scripts/vault/policies/github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab.hcl"
cloud_lab_role="${repo_root}/scripts/vault/roles/github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab.json"
existing_one_policy="${repo_root}/scripts/vault/policies/github-actions-platform-ops-toolkit-uat-xconnect-existing-one.hcl"
existing_one_role="${repo_root}/scripts/vault/roles/github-actions-platform-ops-toolkit-uat-xconnect-existing-one.json"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"
runner="${repo_root}/.github/scripts/xconnect-lab/run.sh"
topology_policy="${repo_root}/.github/scripts/xconnect-lab/validate-topology.jq"
gateway="${repo_root}/.github/scripts/xconnect-lab/gateway.sh"
legacy_existing_one_workflow="${repo_root}/.github/workflows/xconnect-one-uat.yaml"
existing_one_deploy="${repo_root}/.github/scripts/xconnect-existing-one-uat/deploy.sh"
role="github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab"

bash -n "${roles}"
test -f "${cloud_lab_policy}"
test -f "${cloud_lab_role}"
test -f "${existing_one_policy}"
test -f "${existing_one_role}"

python3 - "${cloud_lab_role}" "${existing_one_role}" <<'PY'
import json
import sys
from pathlib import Path

expected_claims = {
    "github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab": {
        "repository": "ai-workspace-infra/platform-ops-toolkit",
        "job_workflow_ref": [
            "ai-workspace-infra/platform-ops-toolkit/.github/workflows/xconnect-zero-cloud.yaml@refs/heads/main",
            "ai-workspace-infra/platform-ops-toolkit/.github/workflows/xconnect-runtime-control.yml@refs/heads/main",
        ],
        "ref": "refs/heads/main",
        "environment": "uat",
    },
    "github-actions-platform-ops-toolkit-uat-xconnect-existing-one": {
        "repository": "ai-workspace-infra/platform-ops-toolkit",
        "job_workflow_ref": "ai-workspace-infra/platform-ops-toolkit/.github/workflows/xconnect-zero-cloud.yaml@refs/heads/main",
        "ref": "refs/heads/main",
    },
}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


for value in sys.argv[1:]:
    role = json.loads(Path(value).read_text(encoding="utf-8"))
    role_name = role.get("role_name")
    if role_name not in expected_claims:
        raise SystemExit(f"unexpected XConnect UAT Vault role: {role_name!r}")
    if role.get("bound_claims") != expected_claims[role_name]:
        raise SystemExit(f"{role['role_name']} must use the exact Toolkit workflow claim set")
    if any("*" in claim for claim in strings(role["bound_claims"])):
        raise SystemExit("XConnect UAT workflow claims must not contain wildcards")
    if role.get("bound_audiences") != ["vault"]:
        raise SystemExit(f"{role['role_name']} must bind only the Vault audience")
    if role.get("token_policies") != [role["role_name"]]:
        raise SystemExit(f"{role['role_name']} must bind only its environment-specific policy")
    if role.get("token_no_default_policy") is not True:
        raise SystemExit(f"{role['role_name']} must disable Vault's default policy")
PY

grep -Fq 'path "kv/data/prod/ulighthost-xconnect/tw-xconnect.svc.plus"' "${cloud_lab_policy}"
if grep -Fq 'path "kv/data/prod/*"' "${cloud_lab_policy}"; then
  echo "XConnect cloud lab must not receive broad production access" >&2
  exit 1
fi
grep -Fq 'path "kv/data/uat/xconnect-one"' "${cloud_lab_policy}"
grep -Fq 'path "kv/data/CICD/observability"' "${cloud_lab_policy}"
grep -Fq 'path "kv/data/CICD/domains/svc.plus"' "${cloud_lab_policy}"
grep -Fq 'path "kv/metadata/CICD/domains/svc.plus"' "${cloud_lab_policy}"
grep -Fq 'path "kv/data/prod/ulighthost-xconnect/observability.svc.plus"' "${existing_one_policy}"
grep -Fq 'kv/data/prod/ulighthost-xconnect/${{ env.ONE_VAULT_KEY }} host | ONE_HOST' "${workflow}"
grep -Fq 'kv/data/prod/ulighthost-xconnect/${{ env.GATEWAY_VAULT_KEY }} ssh_private_key_b64 | GATEWAY_SSH_PRIVATE_KEY_B64' "${workflow}"
grep -Fq 'GATEWAY_HOST: ${{ steps.runtime.outputs.GATEWAY_HOST }}' "${workflow}"
grep -Fq 'GATEWAY_USER: ${{ steps.runtime.outputs.GATEWAY_USER }}' "${workflow}"
grep -Fq 'path "kv/data/prod/ulighthost-xconnect/*"' "${existing_one_policy}"
grep -Fq 'path "kv/data/CICD/domains/svc.plus"' "${existing_one_policy}"

if grep -Fq '"${WF_PREFIX}/xconnect-cloud-lab.yml@*"' "${roles}"; then
  echo "XConnect cloud lab must use its dedicated main-only role, not the general workflow allowlist" >&2
  exit 1
fi

grep -Fq "XCONNECT_VAULT_ROLE: ${role}" "${workflow}"
grep -Fq 'deployment_profile:' "${workflow}"
grep -Fq 'inputs.deployment_profile == '\''existing-one'\''' "${workflow}"
grep -Fq 'inputs.deployment_profile == '\''cloud-lab'\''' "${workflow}"
grep -Fq 'options: [external, aws-spot]' "${workflow}"
grep -Fq 'name: Existing UAT One /' "${workflow}"
if test -e "${legacy_existing_one_workflow}"; then
  echo "The existing-One path must be dispatched through xconnect-zero-cloud.yaml" >&2
  exit 1
fi
# apply and explicit cleanup are separate jobs; each must authenticate with the
# same workflow-scoped role instead of passing a Vault token across jobs.
[[ $(grep -Fc 'role: ${{ env.XCONNECT_VAULT_ROLE }}' "${workflow}") -ge 2 ]]
if grep -Eq '^  schedule:' "${workflow}"; then
  echo "XConnect cloud lab must be released from an immutable UAT snapshot, not a schedule" >&2
  exit 1
fi
grep -Fq -- '-f "$ROOT/.github/scripts/xconnect-lab/validate-topology.jq"' "${runner}"
grep -Fq ".spec.vault.role == \"${role}\"" "${topology_policy}"

grep -Fq 'kv/data/CICD/uat/iac_state TF_STATE_ENDPOINT' "${workflow}"
grep -Fq 'kv/data/uat/xconnect-one ZERO_SERVICE_TOKEN' "${workflow}"
grep -Fq 'kv/data/uat/xconnect-one ZERO_OWNER_EMAIL' "${workflow}"
grep -Fq 'gitops/vpn-overlay/uat/xconnect-lab.json' "${runner}"
grep -Fq 'xconnect-gateway init' "${gateway}"
grep -Fq 'kv/data/prod/ulighthost-xconnect/${{ env.ONE_VAULT_KEY }}' "${workflow}"
grep -Fq 'kv/data/prod/ulighthost-xconnect/${{ env.ONE_VAULT_KEY }} sudo_password | ONE_BECOME_PASSWORD' "${workflow}"
grep -Fq "default: 'tw-xconnect.svc.plus'" "${workflow}"
grep -Fq 'GATEWAY_SERVER_NAME: ${{ inputs.external_gateway_server_name || '\''tw-xconnect.svc.plus'\'' }}' "${workflow}"
grep -Fq 'kv/data/CICD/domains/svc.plus tls_fullchain_pem_b64' "${workflow}"
grep -Fq 'kv/data/CICD/domains/svc.plus tls_key_pem_b64' "${workflow}"
grep -Fq 'GATEWAY_TLS_CERT_B64' "${workflow}"
grep -Fq 'GATEWAY_RELEASE_TAG' "${workflow}"
grep -Fq 'xconnect_one_expected_network_id=$ZERO_NETWORK_ID' "${existing_one_deploy}"
grep -Fq 'xconnect_one_expected_xray_loopback_port=$one_loopback_port' "${existing_one_deploy}"
grep -Fq 'ONE_SERVER_NAME: observability.svc.plus' "${workflow}"
grep -Fq 'UAT existing-One Vault SSH endpoint must be a valid IPv4 address or DNS hostname' "${existing_one_deploy}"
grep -Fq 'Using the Vault-provided existing-One SSH endpoint' "${existing_one_deploy}"
grep -Fq 'apt-get install -y -qq ca-certificates curl jq wireguard-tools' "${existing_one_deploy}"
grep -Fq 'install -m 755 /tmp/xconnect-gateway /usr/local/bin/xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'install -m 755 /tmp/xray /usr/local/lib/xconnect-gateway/xray' "${existing_one_deploy}"
grep -Fq 'getent group caddy' "${existing_one_deploy}"
grep -Fq 'install -d -o root -g caddy -m 0750 /etc/xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'install -o root -g caddy -m 0640 /tmp/gateway.tls.key' "${existing_one_deploy}"
grep -Fq 'install -d -o root -g caddy -m 0750 /run/xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'Environment=PATH=/usr/local/lib/xconnect-gateway/bin' "${existing_one_deploy}"
grep -Fq 'Group=caddy' "${existing_one_deploy}"
grep -Fq 'RuntimeDirectory=xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'xconnect-gateway init --state-dir /var/lib/xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'xconnect-gateway join --state-dir /var/lib/xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'xconnect-gateway up --state-dir /var/lib/xconnect-gateway' "${existing_one_deploy}"
grep -Fq 'reconcile-stable-owner' "${existing_one_deploy}"
grep -Fq 'Stable UAT Gateway ownership reconciliation passed' "${existing_one_deploy}"
grep -Fq 'an invisible Gateway is not a valid result' "${existing_one_deploy}"
grep -Fq 'Zero API returned HTTP 401' "${existing_one_deploy}"
grep -Fq 'rotate an orphaned stable Gateway credential' "${existing_one_deploy}"
grep -Fq 'del(.device_credential, .signing_keys, .enrollment_token' "${existing_one_deploy}"
grep -Fq '.controller = $controller' "${existing_one_deploy}"
grep -Fq 'A previously interrupted recovery can leave the credential empty' "${existing_one_deploy}"
grep -Fq 'systemctl enable --now xconnect-gateway-sync.timer' "${existing_one_deploy}"
grep -Fq '.device_credential.credential' "${existing_one_deploy}"
if grep -Fq '.credential.credential' "${existing_one_deploy}"; then
  echo 'Gateway state checks must use the current device_credential field' >&2
  exit 1
fi
grep -Fq 'gateway_ssh=(sshpass -e ssh' "${existing_one_deploy}"
grep -Fq 'gateway_scp=(sshpass -e scp' "${existing_one_deploy}"
grep -Fq 'Gateway SCP upload failed after three attempts' "${existing_one_deploy}"
grep -Fq 'Managed by XConnect Zero UAT reconciliation' "${existing_one_deploy}"
grep -Fq 'reverse_proxy unix//run/xconnect-gateway/xray.sock' "${existing_one_deploy}"
grep -Fq '/etc/caddy/conf.d/xconnect-gateway.caddy' "${existing_one_deploy}"
if grep -Fq 'shared Caddy fallback marker not found' "${existing_one_deploy}"; then
  echo 'Gateway deployment must not depend on an Agent Proxy Caddy fallback marker' >&2
  exit 1
fi
grep -Fq 'Gateway peer reconciliation failed after three attempts' "${existing_one_deploy}"
grep -Fq 'ONE_BECOME_PASSWORD' "${existing_one_deploy}"
grep -Fq -- '--become-password-file "$one_become_password"' "${existing_one_deploy}"
grep -Fq 'one_sudo()' "${existing_one_deploy}"
grep -Fq 'ONE_USER" == "root" || "$ONE_USER" == "ubuntu' "${existing_one_deploy}"
grep -Fq 'ssh-keygen -F "$ssh_host" -f "$known_hosts"' "${existing_one_deploy}"
grep -Fq 'cat "${HOME}/.ssh/known_hosts" >>"$known_hosts"' "${existing_one_deploy}"
grep -Fq 'ControlMaster=auto' "${existing_one_deploy}"
grep -Fq 'ControlPath=/tmp/xconnect-%C' "${existing_one_deploy}"
grep -Fq 'query["controller"] = [controller]' "${existing_one_deploy}"
grep -Fq 'ZERO_ACCOUNTS_API_URL: https://uat-accounts-1004637461064.asia-northeast1.run.app' "${workflow}"
grep -Fq 'ONE_USER" == "root' "${existing_one_deploy}"
grep -Fq 'sudo -S -p' "${existing_one_deploy}"
if grep -Fq 'scp "${gateway_ssh[@]}' "${existing_one_deploy}"; then
  echo 'existing-One deploy must not pass ssh argv to scp' >&2
  exit 1
fi
if grep -Fq 'ssh "${gateway_ssh[@]}' "${existing_one_deploy}"; then
  echo 'existing-One deploy must not prefix the ssh argv array with another ssh' >&2
  exit 1
fi
if grep -Fq 'getent ahostsv4 "$ONE_SERVER_NAME"' "${existing_one_deploy}"; then
  echo 'existing-One migration must not require the Vault SSH endpoint to match current DNS' >&2
  exit 1
fi
if grep -Fq 'ONE_HOST" != "$ONE_SERVER_NAME' "${existing_one_deploy}"; then
  echo 'existing-One migration must not compare the Vault SSH endpoint with the logical server name' >&2
  exit 1
fi

echo "XConnect UAT cloud-lab Vault role contract is pinned to the workflow on main."
