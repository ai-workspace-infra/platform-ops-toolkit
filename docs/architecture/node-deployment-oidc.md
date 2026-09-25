# Provider-neutral OIDC and node deployment

## Design boundary

GitOps declares desired resources and service stages; `iac_modules` renders and
creates provider resources; `platform-ops-toolkit` orchestrates identity,
state, validation, and playbook execution; `playbooks` owns host configuration.
The shared node contract is the seam between Terraform outputs and Ansible.
It contains resolved addresses and non-secret connection metadata, not
provider-specific Terraform fields or credentials.

```text
GitHub Actions job OIDC JWT
   ├─ audience=vault ─> Vault JWT role ─> scoped short-lived Vault token
   │                                  └─> only that stage's internal secrets
   └─ provider audience ─> provider federation ─> short-lived cloud session
                                            └─> IaC / short-lived SSH identity
                                                       └─> common Ansible contract
```

The GitHub OIDC token is the workload identity assertion, not a reusable cloud
credential. Each job requests a fresh token with a specific audience. Vault
roles are separate from provider roles and should bind the immutable GitHub
repository and owner IDs, protected environment, branch/ref, and exact caller
or reusable workflow claim. Policies grant only the required KV paths and
operations. A Vault JWT token should be batch, short-lived, non-renewable, and
have no default policy.

## Provider adapter model

Keep one provider-neutral deployment contract and one adapter per provider or
credential mechanism. Provider-specific authentication must be implemented
only where that provider has a supported federation flow; do not assume that a
VPS API supports OIDC just because the workflow itself has a GitHub OIDC token.

| Concern | Shared contract | Current implementation/status |
| --- | --- | --- |
| VM creation | GitOps declaration → provider IaC renderer | Existing renderers remain provider-specific |
| Runtime facts | node id, provider, reachable address, SSH port/user, Ansible groups | Validator and inventory renderer added in `scripts/node_deploy/` |
| GCP identity | GitHub OIDC → Vault JWT role → Google WIF/STS | Used by the shared GCP IaC workflow; OS Login is the planned ephemeral SSH path |
| AWS identity | GitHub OIDC → Vault JWT role → AWS STS role session | Keep existing AWS OIDC workflow and module unchanged |
| VPS identity | GitHub OIDC → Vault JWT role, then provider-supported short session or a narrowly scoped Vault-issued credential | Adapter is provider-specific and not assumed implemented |
| Host access | Short-lived OS Login key, SSH user certificate, or one-run SSH key | Only the GCP OS Login adapter is in scope for the first rollout |
| Service setup | Ansible inventory + selected playbook stages | Shared Vault playbooks consume normal Ansible groups and explicit stage variables |

When a provider offers no workload federation, use a provider-specific Vault
JWT role to release the narrowest available credential, prefer a short lease,
and document rotation/revocation. Do not store a provider API token in GitOps,
Terraform state, workflow inputs, or the normalized node contract. For VPS
SSH, prefer a Vault SSH CA issuing short-lived user certificates; until that
CA exists, a one-run key must be created and installed through a controlled
out-of-band process, then revoked/removed. Never fall back silently to a
long-lived shared SSH key.

## Node contract

`scripts/node_deploy/render_inventory.py` accepts a resolved
`ops.svc.plus/v1alpha1` `NodeDeployment` document and writes a strict Ansible
INI inventory. Each stage maps to explicit target groups, so a mixed-provider
fleet can deploy only to nodes whose authentication adapter has been prepared.
Provider resource renderers should construct this document from the GitOps
declaration plus post-apply runtime outputs. The contract
supports public IPv4, private overlay addresses, or DNS names, allowing a VPS
and cloud VMs to join the same deployment stages.

The `auth.adapter` field names a credential capability, never a credential:

- `gcp-oslogin-ephemeral` — Google WIF identity adds a short-lived OS Login key.
- `ssh-certificate` — an SSH CA issues a short-lived user certificate.
- `ephemeral-ssh-key` — a provider integration installs a one-run public key.

The validator currently accepts these adapter names to keep the contract
stable, but the shared GCP workflow only implements the GCP adapter. Workflows
must fail closed if a declared adapter does not have a concrete issuer,
scoped permissions, host-key verification, and cleanup/revocation step.

## OIDC and secret separation

- IaC job role: reads only provider identity metadata and the shared remote
  state fields needed to run Terraform.
- Node configuration role: reads only the service configuration fields needed
  by the selected playbook stage (for example observability credentials or
  XConnect enrollment material); it cannot mutate cloud IAM or Terraform state.
- Bootstrap role: one-time setup only; it is not reused by deployment jobs.
- Manual Vault initialization/unseal remains an operator procedure. Root token,
  unseal shares, and one-time XConnect invitations are never workflow secrets.
- Temporary SSH private keys/certificates are created on the runner, held only
  for the job, and removed in an `always()` cleanup step. GitHub-hosted job
  logs and artifacts must not contain them.

The shared Vault deployment uses `prod` as its GitHub Environment. Before a
real production rollout, configure required reviewers on that Environment and
verify approval enforcement; an Environment name alone is not an approval
rule. The current bootstrap connection mode runs on a GitHub-hosted runner:
after WIF authentication, the job creates a uniquely named GCP firewall rule
allowing TCP/22 from `0.0.0.0/0` to `vault`-tagged VMs for this run only. It
uses an expiring OS Login key, compares live Ed25519 host keys to reviewed
GitOps pins, and has both in-job and independent cleanup. A canceled workflow
can still leave a rule if both cleanup paths are interrupted; operators must
check for and delete any `vault-shared-ci-ssh-*` rule before declaring the run
complete. This temporary exposure is accepted only during initial enrollment.

The installation job always uses an automatically allocated GitHub-hosted
`ubuntu-latest` runner; it does not require a registered self-hosted runner.
After XConnect Zero assigns and verifies each node's overlay IP and internal
DNS, add a per-job, short-lived XConnect One enrollment for that hosted runner,
then update GitOps to `xconnect-zero` and remove the public `/32` SSH
allowlist. The `xconnect-zero` workflow input remains unavailable until that
ephemeral runner adapter is implemented and tested. The service stage refuses
to run when its selected connection mode does not match the reviewed GitOps
manifest. The runner is an execution boundary, not a credential: it receives
per-job OIDC tokens and short-lived identities and must not have persistent
cloud credentials.

## Workflow layout

```text
vault-server.yml (entry, provider = gcp-cloud)
  ├─ declaration      GitOps service + provider manifests → environment, Vault paths, mode
  ├─ gcp-shared       optional IaC plan/apply (gcp-iac-pipeline.yml)
  └─ node-stage       uses vault-shared-iac.yml (provider-neutral, one stage)
        ├─ declaration     stage plan (scripts/node_deploy/stage_plan.py)
        ├─ node-stage      adapter open → host-key pin → gate → playbook → confirm → adapter close
        └─ cleanup-node-access  adapter close again (always)
```

A provider adapter is a composite action with an `open` and a `close` phase.
`open` emits `contract` (NodeDeployment JSON), `ssh_private_key`, and
`auth_adapter`; `close` revokes the credential and removes any temporary
ingress. `.github/actions/node-access-gcp` is the only file that knows about
Google WIF, OS Login, and GCP firewall rules. A VPS or other-cloud adapter
adds one `open` step and one `close` step in `vault-shared-iac.yml`; the
stage plan, gates, and playbooks stay the same.

The Vault JWT roles bind `workflow_ref` to `vault-server.yml` on `main`. For a
reusable workflow, GitHub keeps the caller in `workflow_ref`, so the roles do
not change when stages run inside `vault-shared-iac.yml`.

## Rollout order

1. IaC creates the nodes and the private Raft channel (8200/8201 from the
   subnet only). The GCP adapter re-checks the live firewall on every stage.
2. `node-preflight`, `vault-shared-leader`, `vault-shared-peers`,
   `vault-raft-verify`, `node-process-metrics`: one dispatch each, gated on
   live state. Operators init/unseal between dispatches.
3. XConnect Gateway and One: the stage gates exist, but dispatch stays disabled
   until the Gateway frontend, release artifacts, and one-use invitation
   issuance are wired. Then the operator Mac joins with its own one-use
   invitation, GitOps switches to `xconnect-zero`, and IaC removes the public
   SSH allowlist.
4. Migrating data from the old PostgreSQL-backed Vault and moving
   `vault.svc.plus` are separate, operator-run gates with a backup,
   verification, and rollback (see the playbooks operator runbook). The old
   node never joins the new Raft cluster.
