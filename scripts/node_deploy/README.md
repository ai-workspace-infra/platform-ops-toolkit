# Provider-neutral node deployment contract

Terraform/provider workflows own resource creation and emit a small, non-secret
`NodeDeployment` document. The Ansible deployment entrypoint consumes its
rendered inventory and service-stage list; it does not infer GCP/VPS details
from hostnames or maintain a second copy of the topology.

The contract keeps only connection metadata (`provider`, address, SSH port,
OS Login username, inventory groups, and an authentication adapter name). It
must never contain private keys, passwords, access tokens, Vault tokens, or
XConnect enrollment invites. An adapter obtains/creates short-lived connection
material through the provider or a scoped Vault JWT role, and removes it after
the playbook exits.

Supported adapter names are intentionally capabilities, not cloud types:

- `gcp-oslogin-ephemeral`: Google WIF identity adds a short-lived OS Login key.
- `ssh-certificate`: an SSH CA issues a short-lived user certificate.
- `ephemeral-ssh-key`: a deployment adapter provisions a one-run public key.

The inventory renderer is provider-neutral and rejects embedded credentials.
Only `gcp-oslogin-ephemeral` is currently wired by the shared GCP workflow;
the other adapter names define the extension boundary and must not be selected
until their issuer, Vault policy, revocation, and cleanup behavior are deployed.

Example:

```json
{
  "apiVersion": "ops.svc.plus/v1alpha1",
  "kind": "NodeDeployment",
  "metadata": {"name": "vault-shared"},
  "spec": {
    "environment": "shared",
    "stages": ["vault-shared-leader", "vault-shared-peers", "node-process-metrics"],
    "stage_targets": {
      "vault-shared-leader": ["vault_shared_leader"],
      "vault-shared-peers": ["vault_shared_peers"],
      "node-process-metrics": ["vault_shared_nodes"]
    },
    "nodes": [
      {
        "id": "vault-prod-0",
        "provider": "gcp",
        "address": "203.0.113.10",
        "private_address": "10.81.0.4",
        "ssh_user": "gha_1234567890",
        "auth": {"adapter": "gcp-oslogin-ephemeral"},
        "groups": ["vault_shared_nodes", "vault_shared_leader"]
      }
    ]
  }
}
```

Render and verify:

```bash
python3 scripts/node_deploy/render_inventory.py contract.json \
  --inventory /tmp/node-inventory.ini
ansible-inventory -i /tmp/node-inventory.ini --graph
```

After the selected short-lived auth adapters have been prepared, invoke one
declared playbook stage through the common runner:

```bash
NODE_AUTH_ADAPTERS_READY=gcp-oslogin-ephemeral \
  bash scripts/node_deploy/run_stage.sh \
  /tmp/vault-shared-node-deployment.json \
  deploy_vault_shared_services.yml \
  node-process-metrics \
  /path/to/playbooks
```

The runner refuses undeclared stages and any node adapter that the preceding
credential phase did not report as prepared. It uses a mode-0600 temporary
inventory, keeps SSH host-key checking enabled, and removes the inventory on
exit. This readiness marker is a workflow boundary check, not a replacement
for the adapter's token validation or revocation logic.

For VPS providers, resource provisioning can remain a separate GitOps/IaC
adapter while emitting the same contract. Public IP, private overlay address,
or a reachable DNS name are all valid SSH targets. Network reachability and
host-key verification remain explicit requirements; the contract does not
open firewall rules or silently disable SSH host-key checking.

## Stage plan and live-state gates

`stage_plan.py` lists the dispatchable stages in rollout order and, for each,
the live checks it requires before any change (`requires`), the playbook tags
it applies, and the checks that must pass afterwards (`confirms`).
`verify_vault_stage.py` evaluates those checks from one SSH probe per node
(sudo, swap, Vault loopback `sys/health`/`sys/leader`, systemd units). It uses
no Vault token, so CI can gate stages while init, unseal, and the
`raft list-peers` confirmation stay with operators:

```bash
python3 scripts/node_deploy/stage_plan.py vault-shared-peers
python3 scripts/node_deploy/verify_vault_stage.py \
  --contract /tmp/vault-shared-node-deployment.json \
  --key /path/to/short-lived-key --known-hosts /path/to/pinned-known-hosts \
  --checks access,leader-unsealed
```

Stages that are not wired end-to-end (XConnect Gateway/One) stay in the plan
with `enabled: False`, so `stage_plan.py` rejects them with the reason.
