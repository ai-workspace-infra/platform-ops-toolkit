# Shared Vault GCP OIDC prerequisites

This guide prepares the Vault authorization and KV contracts used by the
shared Vault deployment in GCP project `open-platform-prod`. GitHub Actions
uses the protected GitHub Environment `prod`, while Vault paths and Terraform
state use the logical `shared` scope. No Vault root token, unseal shares,
service-account JSON key, or permanent GCP credential belongs in GitHub.

## 1. Install only the shared Vault roles and policies

An authorized Vault administrator runs this from the checked-out
`platform-ops-toolkit` main branch. The default is a read-only check; `--apply`
writes the two shared GCP roles plus the three stage-scoped Vault node roles
and policies (not every repository role):

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

bash scripts/vault/bootstrap_shared_gcp_roles.sh --check
bash scripts/vault/bootstrap_shared_gcp_roles.sh --apply
bash scripts/vault/bootstrap_shared_gcp_roles.sh --check
```

The declarations are stored separately by role name:

- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod.hcl`
- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod.hcl`
- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-vault-node-oidc-open-platform-prod.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-vault-node-oidc-open-platform-prod.hcl`
- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-vault-monitoring.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-vault-monitoring.hcl`
- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-vault-xconnect.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-vault-xconnect.hcl`

The node, monitoring, and XConnect JWT roles bind to
`.github/workflows/vault-server.yml@refs/heads/main`. After changing the
workflow filename, an administrator must run `--apply` again; `--check` now
rejects a role still bound to the previous filename.

The bootstrap role is restricted to this repository, the `prod` GitHub
Environment, the bootstrap workflow, and `main`. It can read only the shared
bootstrap/state records and write the shared runtime OIDC record. The runtime
role can read only the shared runtime OIDC record and shared state record.
The node role reads only shared runtime GCP identity metadata, the monitoring
role only `CICD/observability`, and the XConnect role only
`CICD/shared/xconnect` plus the `svc.plus` TLS record. These roles are bound
to the Vault shared GCP workflow on `main` and must be provisioned before
the corresponding installation stage runs.

## 2. Prepare the shared Terraform state KV record

Obtain the backend endpoint, bucket, region, access key, and secret key from the
approved shared state-store operator/secret manager. Do not copy them into
Git, workflow inputs, or chat. Export them into the current shell from that
secure source, then write and verify the dedicated path:

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

SHARED_IAC_STATE_ACTION=write bash scripts/gcp/bootstrap_shared_iac_state_kv.sh
bash scripts/gcp/bootstrap_shared_iac_state_kv.sh
```

This writes KV v2 path `kv/CICD/shared/iac_state` with exactly these non-empty
fields:

```text
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_REGION
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
```

The script validates the complete record without printing any values. It
refuses to write if a field is absent; it does not invent state-store details
or copy credentials from another environment.

## 3. Prepare the one-time GCP bootstrap token

Use a GCP identity authorized by the project administrator to manage Workload
Identity Federation, service accounts and project IAM in `open-platform-prod`.
The bootstrap process is not self-elevating: if the identity lacks required
permissions, an existing project administrator must grant them out of band.
Do not grant Owner just for this workflow.

With an authorized Vault write session, write the short-lived ADC access token
to the exact shared/account path. The script obtains the token from local ADC
when `GCP_ACCESS_TOKEN` is not set and never prints its value:

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

GCP_ENVIRONMENT=shared \
GCP_ACCOUNT_ID=open-platform-prod \
GCP_PROJECT_ID=open-platform-prod \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh

GCP_BOOTSTRAP_ACTION=check \
GCP_ENVIRONMENT=shared \
GCP_ACCOUNT_ID=open-platform-prod \
GCP_PROJECT_ID=open-platform-prod \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

This initializes `kv/CICD/shared/gcp-bootstrap/open-platform-prod` with
`GCP_ACCESS_TOKEN` and `GCP_PROJECT_ID`. The shared helper rejects a different
project/account mapping and disables the `--auth-json` long-lived-key option.
KV v2 does not expire a value when the OAuth token's TTL expires. Therefore,
write the token shortly before running bootstrap `apply`. After an `apply`,
the workflow attempts to revoke it, deletes previous KV versions, and retains
only `GCP_PROJECT_ID`. If automatic cleanup fails, use the helper's
`GCP_BOOTSTRAP_ACTION=revoke` mode from an authorized local admin session.

## 4. Run the GitHub Actions bootstrap

In **Actions → GCP OIDC Bootstrap**, dispatch with:

```text
environment = shared
action      = plan
```

Inspect the plan. Refresh the short-lived token using the previous step if it
has expired, then dispatch:

```text
environment = shared
action      = apply
```

The job runs in the protected GitHub Environment `prod` (approval required),
creates the GCP WIF pool/provider and deploy service account, verifies the
identity, and writes runtime identity metadata to
`kv/shared/platform/oidc/open-platform-prod`.

## 5. Run Vault infrastructure plan/apply

After bootstrap apply succeeds, dispatch **Vault server** (`.github/workflows/vault-server.yml`).
Its default GitOps service declaration is
`resources/svc.plus/shared/vault/server.yaml`; the GCP adapter reads
`resources/xworktech.com/shared/gcp/vault-shared.yaml`. Its `declaration` job
checks the environment, Vault JWT roles and KV paths, project, network, and
the declared XConnect topology, and its `node-stage` job runs exactly one
`service_stage` for exactly one `service_manifest` at a time. For another
environment, supply its reviewed service and provider manifest paths and
provision the corresponding scoped Vault roles before dispatching. The
node-stage action itself consumes the provider-neutral `NodeDeployment`
contract:

```text
cloud_provider = gcp-cloud
deploy_action  = plan
```

Review that the plan contains the shared VPC/subnet, three `e2-custom-2-2048`
Vault VMs with static public IPv4 addresses, no Cloud NAT, TCP 443 on the
Gateway, and TCP 22 only from `35.79.83.48/32`. No public rule should expose
Vault API port 8200. If the plan is correct, dispatch again with
`deploy_action = apply` and complete the protected `prod` Environment approval.

### Node stages: one per dispatch

`vault-server.yml` is the GCP entry point. It runs IaC (when
`deploy_action` is `plan` or `apply`) and then runs its provider-neutral
`node-stage` job for exactly one `service_stage`. Use
`deploy_action=none` to run a node stage against existing VMs without another
Terraform apply; `plan` cannot be combined with a node stage.

Every node stage opens access the same way through the GCP adapter
(`.github/actions/node-access-gcp`): Vault JWT → Google WIF, a 65-minute
OS Login key, a live check that the private Raft firewall rule allows
8200/8201 only from the declared subnet, and (in `bootstrap-public` mode) a
temporary `vault-shared-ci-ssh-<run>-<attempt>` rule for TCP/22. Live SSH host
keys must match the GitOps pins. The rule and key are removed at the end of
the job and again by an independent cleanup job. Check that no
`vault-shared-ci-ssh-*` rule remains, even if the workflow was canceled.

Before changing anything, each stage probes every node over SSH (sudo, swap,
Vault's loopback `sys/health` and `sys/leader`, service units) and refuses to
run unless its prerequisites hold. The probe needs no Vault token.

#### Fresh environment (no existing Vault)

IaC → preflight → leader → manual init/unseal → one peer per dispatch
(manual unseal + `raft list-peers` after each) → quorum → monitoring and
XConnect → service verification.

| Order | `service_stage` | Requires (checked live) | Does | Then, manually |
| --- | --- | --- | --- | --- |
| 1 | `node-preflight` | SSH, sudo, no swap | nothing | — |
| 2 | `fresh-leader` | same + no split cluster | installs Vault on node 0 | `vault operator init` + unseal node 0 |
| 3 | `fresh-peers` (repeat) | node 0 unsealed; every joined peer unsealed | installs Vault on the **next** peer only | unseal it; `vault operator raft list-peers`; dispatch again for the next peer |
| 4 | `vault-raft-verify` | all nodes unsealed, one cluster ID, one active, same private Raft leader | nothing | confirm all voters |
| 5 | `node-process-metrics` | SSH | node exporter, process exporter, Vector | — |
| 6–9 | `xconnect-gateway-frontend`, `xconnect-gateway`, `xconnect-one`, `xconnect-operator-invite` | see below | XConnect | see below |
| 10 | `vault-service-verify` | quorum, monitoring, Gateway running, `https://vault.svc.plus` answers unsealed as this cluster | nothing | — |

#### Migration of the existing vault.svc.plus node

Target IaC/preflight/monitoring → read-only check of the old node → old
node to single-node Raft → encrypted snapshot + restore drill → XConnect
between the old cluster and the new nodes → new nodes join **one at a time**
→ manual unseal / voter / quorum → leader transfer + cluster health → DNS
switch (the last traffic change) → observation and rollback window → remove
the old peer and retire the node → manual rekey, rotate, revoke the old root
token. `migrate-auto` (confirm `MIGRATE-VAULT-AUTO`) picks the next of these
from live state and stops at every manual gate.

| Order | `service_stage` | Requires (checked live) | Does | Then, manually |
| --- | --- | --- | --- | --- |
| 1 | `node-preflight`, `node-process-metrics` | SSH | target nodes checked and monitored for the whole migration | — |
| 2 | `xconnect-gateway-frontend`, `xconnect-gateway`, `xconnect-one` | see below | overlay; `xconnect-one` also enrolls the old node (no Vault change) | record `spec.migration.source.overlay_address` |
| 3 | `migrate-preflight` | old node unsealed; disk; storage | read-only report | — |
| 4 | `migrate-convert` (`CONVERT-VAULT-TO-RAFT`) | old node unsealed, report, overlay address declared | PostgreSQL → single-node Raft in place (its Raft address is the overlay address) | unseal it with its existing key |
| 5 | `vault-snapshot` | `spec.backup` | snapshot → restore drill in a disposable Raft Vault → age encryption → upload → read-back check → manifest | keep the age identity and unseal keys offline |
| 6 | `migrate-join` (repeat) | old node active on Raft; one cluster; **every node reaches every other on 8200/8201 over the overlay**; every joined node unsealed | snapshot + drill first, then joins the **next** new node only | unseal it with the existing key; `raft list-peers`; dispatch again |
| 7 | `migrate-cutover` (`MOVE-VAULT-LEADER`) | all nodes unsealed, one cluster, one leader | snapshot + drill, then steps the old node down until a new node leads; confirms old node standby **and** a healthy quorum | switch `vault.svc.plus` DNS; record `spec.migration.observation.dns_switched_at` |
| 8 | observation window | — | nothing: the old node stays a voter and forwards to the leader | rollback = point the DNS back at the old node |
| 9 | `migrate-remove` (`REMOVE-LEGACY-VAULT-PEER`) | old node standby, DNS no longer on it, `dns_switched_at + hours` passed (default 24) | snapshot + drill, removes the old Raft peer, stops and disables the old Vault | — |
| 10 | `vault-service-verify` | as in the fresh path | nothing | rekey, rotate and revoke the old root token (M7) |

`spec.migration.observation` in the Vault service declaration:

```yaml
spec:
  migration:
    observation:
      dns_switched_at: 2026-10-01T08:00:00Z   # when vault.svc.plus moved (UTC offset required)
      hours: 24                             # 1–720, default 24
```

#### XConnect stages

| `service_stage` | Requires (checked live) | Does | Then, manually |
| --- | --- | --- | --- |
| `xconnect-gateway-frontend` | SSH | Caddy on node 0: TLS 443 for `vault-xconnect.svc.plus`, only `/xconnect` forwarded | point `vault-xconnect.svc.plus` at node 0 |
| `xconnect-gateway` | SSH (not Raft: the old node joins over this overlay) | installs the verified runtime, `init`, issues a one-use invitation bound to the Gateway key, enrolls, starts Xray + sync; confirms `gateway-running` | check the Gateway in the Zero portal |
| `xconnect-one` | Gateway enrolled | enrolls vault-prod-1/2 and, while `spec.migration` is declared, the existing vault.svc.plus node (M4) as One; one invitation per node that has not joined | record overlay IPs in GitOps (`fixed_nodes[].xconnect.overlay_ip`, `spec.migration.source.overlay_address`) |
| `xconnect-operator-invite` | Gateway enrolled | issues a one-use invitation for the operator device declared in GitOps and writes it to `kv/data/CICD/shared/xconnect-operator-invite` (CI can create/update, never read); no host change | on the Mac within 30 min: `vault kv get -field=join_uri kv/CICD/shared/xconnect-operator-invite`, then `xconnect join` |

The Zero access policy must allow tcp 8200/8201 between the Vault nodes and
the old node before `migrate-join`; the stage checks the path from every
node and refuses when packets are dropped.

`xconnect-gateway` needs, in `kv/data/CICD/shared/xconnect`: `ZERO_SERVICE_TOKEN`,
`ZERO_OWNER_EMAIL` and `VLESS_ID` for the shared network (not the UAT values).
The xconnect role also reads the `svc.plus` trust bundle and the GitHub App key
that mints a read-only token for the private XConnect releases; re-apply the
roles (`bootstrap_shared_gcp_roles.sh --apply`) after pulling this policy.
Re-running the stage on an enrolled Gateway issues no invitation.

Initialization and unsealing always happen in a secured operator terminal
(see `docs/vault/operator-runbook.md` in `playbooks`). GitHub Actions never
receives the root token, unseal shares, or an operator credential, so the
`vault operator raft list-peers` confirmation also stays manual.

XConnect Zero network/policy creation, Gateway and One enrollment, DNS cutover,
and the zero-trust SSH adapter remain separate checkpoints. Do not remove the
operator `/32` SSH allowlist until all three overlay addresses and internal DNS
names are verified. GitHub Actions must never receive Vault root tokens or
unseal shares. Note that naming the GitHub Environment `prod` does not itself
enforce approval: configure required reviewers in repository settings before
running production installation.
