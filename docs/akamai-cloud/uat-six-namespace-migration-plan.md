# Akamai Cloud UAT six-namespace migration plan

> Status: planning only. This document does not authorize Terraform `plan`,
> `apply`, `import`, `destroy`, Playbooks, DNS changes, data migration, or cloud
> resource mutations.

This is the canonical, code-agent-readable execution contract for the Akamai
Cloud/Linode UAT migration. Codex, Claude Code, GitHub Copilot, CI agents, and
human operators must use the same phases, state keys, safety boundaries, and
acceptance gates defined here.

## Tracking and source repositories

| Kind | Link | Purpose |
|---|---|---|
| GitHub Project | [ai-workspace-infra Project 1](https://github.com/orgs/ai-workspace-infra/projects/1) | Cross-repository status and sequencing |
| Epic | [platform-ops-toolkit#838](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/838) | Stages A-E and final acceptance |
| Stage A | [platform-ops-toolkit#845](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/845) | Six states and infrastructure resources |
| Stages B-E | [platform-ops-toolkit#846](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/846) | Bootstrap, workloads, migrations, cutover, and cleanup gates |
| Web SaaS | [platform-ops-toolkit#841](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/841) | Standard Selfhost UAT deployment; no migration |
| AI Workspace | [platform-ops-toolkit#840](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/840) | Application rebuild and QMD memory migration |
| Agent Proxy | [platform-ops-toolkit#839](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/839) | JP/US/SG plus TW/PH deployment matrix |
| Open Platform | [platform-ops-toolkit#842](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/842) | Vault and Observability controlled migration |

Repository responsibilities:

| Repository | Responsibility |
|---|---|
| [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) | Linode provider tree, renderer, six workdirs/states, Terraform tests |
| [`gitops`](https://github.com/ai-workspace-infra/gitops) | Desired non-secret resource declarations and account facts |
| [`playbooks`](https://github.com/ai-workspace-infra/playbooks) | Node bootstrap, Caddy, workloads, agents, and migration roles |
| [`platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | Vault/OIDC loading, routing, approvals, workflows, inventory, and gates |

## Implemented code contracts

The following merged pull requests publish code contracts only. They do not
prove that the six UAT resources exist.

| Repository | Pull request | Contract |
|---|---|---|
| `iac_modules` | [#322](https://github.com/ai-workspace-infra/iac_modules/pull/322) | Six UAT state namespaces and canonical `svc.plus` keys |
| `iac_modules` | [#323](https://github.com/ai-workspace-infra/iac_modules/pull/323) | Production compute protection without changing UAT isolation |
| `gitops` | [#272](https://github.com/ai-workspace-infra/gitops/pull/272) | Six single-host UAT Akamai declarations |
| `playbooks` | [#458](https://github.com/ai-workspace-infra/playbooks/pull/458) | Debian/root identity and Vault PostgreSQL fixes |
| `platform-ops-toolkit` | [#844](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/844) | Namespace routing, workdirs, and destroy guards |
| `platform-ops-toolkit` | [#847](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/847) | Read-only migration preflight |
| `platform-ops-toolkit` | [#848](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/848) | Protected source identity correction |
| `platform-ops-toolkit` | [#849](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/849) | Valid disposable S3 backend preflight |
| `platform-ops-toolkit` | [#850](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/850) | Runtime Linode token normalization |

The successful read-only baseline is
[workflow run 35662963134](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/35662963134):

- all six target namespaces are `absent`;
- the candidate legacy `selfhost` state is absent;
- no state move is currently possible or required;
- no `apply`, `import`, `destroy`, deployment, or DNS change was performed.

If a later preflight finds an existing instance or another historical state,
stop and reclassify the resource as `import`, `adopt`, or `create`. Never create
a duplicate instance from stale assumptions.

## Immutable safety contract

The existing source node is:

```text
ssh ubuntu@observability.svc.plus
```

It must:

- remain outside every new Terraform state;
- remain outside Akamai GitOps resource manifests;
- never be targeted by Terraform `import`, `apply`, or `destroy`;
- retain its SSH identity, disks, system configuration, and existing services;
- permit only explicitly approved read-only exports during migration;
- remain available as a rollback source after successful cutover;
- never be included in automated cleanup.

`observability.svc.plus` may be configured as a service domain on the new
Open Platform node. That domain reference must never be interpreted as the
identity of the old managed host.

## Canonical state contract

```text
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/<namespace>/terraform.tfstate
```

| Namespace | Purpose | Lifecycle |
|---|---|---|
| `web-saas` | UAT Web SaaS full stack | Temporary; namespace-scoped cleanup allowed after acceptance |
| `open-platform` | Vault and Observability platform services | Permanent; destroy denied |
| `ai-workspace` | xworkmate-bridge, QMD, and AI Workspace | Temporary; namespace-scoped cleanup allowed after acceptance |
| `agent-proxy-jp` | Japan Agent Proxy | Temporary; namespace-scoped cleanup allowed after acceptance |
| `agent-proxy-us` | United States Agent Proxy | Temporary; namespace-scoped cleanup allowed after acceptance |
| `agent-proxy-sg` | Singapore Agent Proxy | Temporary; namespace-scoped cleanup allowed after acceptance |

`selfhost` and shared aggregate state remain forbidden. The workflow UI may use
`target_domains=all` only as a Stage A dispatch selector; it is not a Terraform
workspace or state key. In that mode the parent orchestrator sequentially
dispatches the six isolated namespaces below and never runs Terraform against
an aggregate state. `deploy`, `migrate`, `deploy+migrate`, and `destroy` still
require selecting one namespace explicitly.

## Stage A: build six isolated Terraform resources

Tracking issue: [#845](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/845).

Recommended order:

```text
open-platform
-> web-saas
-> ai-workspace
-> agent-proxy-jp
-> agent-proxy-us
-> agent-proxy-sg
```

For each namespace, execute only after explicit authorization:

1. Freeze the `iac_modules`, `gitops`, and `platform-ops-toolkit` main SHAs.
2. Generate one Terraform workdir.
3. Verify the exact backend key and lockfile scope.
4. Run `terraform init -reconfigure`.
5. Run `terraform validate`.
6. Read the live Linode inventory again.
7. Run `terraform plan`.
8. Have a human confirm region, plan, label, monthly cost, public networking,
   firewall rules, backups, and replacement/destroy actions.
9. Apply only that approved namespace.
10. Run a second plan and require `0 add / 0 change / 0 destroy`.
11. Write an independent, secret-free inventory and CMDB record.

Every plan must contain only the selected instance and its associated
namespace resources. A reference to another namespace, the protected source,
an unapproved replacement, or an implicit destroy is a hard stop.

### Stage A workflow fan-out

Use the Selfhost Orchestrator with:

```text
vault_env_path=uat
target_domains=all
target_domain_base=onwalk.net
cloud_provider=akamai-cloud
akamai_account=<concrete account name>
operation=plan              # review only
operation=infra             # apply after review
```

`operation=all` is not a valid operation. `operation=plan` runs the six child
plans in the order above. `operation=infra` runs each child apply, then runs a
fresh plan for that same child and requires `0 add / 0 change / 0 destroy`
before proceeding to the next namespace. A failed child stops the fan-out;
there is no automatic destroy or rollback.

Stage A acceptance:

- six unique state keys and lock scopes exist;
- all six post-apply plans are 0/0/0;
- each state contains only its own instance and firewall;
- AI Workspace is actually `sg-sin-2 / g8-dedicated-8-4` (4C8G);
- Open Platform destroy is rejected;
- six inventory/CMDB records exist and contain no credentials;
- no workload, data migration, or DNS cutover has occurred;
- the protected source node is unchanged.

## Stage B: initialize the new nodes

Tracking issue: [#846](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/846).

Apply a common baseline to all six new nodes:

- SSH user and sudo initialization;
- operating-system updates and security baseline;
- Caddy base configuration;
- Docker/container runtime;
- host, container, metric, and log agents;
- connection to `https://observability.svc.plus/`;
- inventory and CMDB update;
- SSH, HTTPS, reboot recovery, and monitoring-heartbeat acceptance.

Stage B must not migrate Vault, Observability, or QMD data and must not change
DNS.

## Stage C: deploy four workload classes

### C1 Web SaaS: clean standard deployment

Tracking issue: [#841](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/841).

Use the standard Selfhost UAT pipeline:

```text
bootstrap
-> database initialization
-> full-stack deployment
-> Caddy/DNS/TLS validation
-> end-to-end health
-> idempotent rerun
```

The target includes `console-selfhost-uat.onwalk.net`. Do not migrate old Web
SaaS databases, configuration directories, container volumes, or runtime
state from the protected source.

### C2 Open Platform: controlled migration

Tracking issue: [#842](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/842).

Services:

- `vault.svc.plus`;
- `observability.svc.plus`.

Planned sequence:

```text
empty target deployment
-> verified backups
-> isolated restore rehearsal
-> approved read-only export/sync
-> Vault and Observability integrity checks
-> dual-end health
-> change-window approval
-> DNS/entrypoint cutover
-> observation
-> acceptance or rollback
```

Validate Vault seal/unseal, policies, JWT roles, KV data, metrics, logs,
alerts, historical data, and recovery behavior. Never delete the source node.

### C3 AI Workspace: rebuild applications and migrate QMD memory

Tracking issue: [#840](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/840).

Target contract:

```yaml
namespace: ai-workspace
region: sg-sin-2
plan: g8-dedicated-8-4
resources: 4C8G
```

Rebuild xworkmate-bridge, QMD runtime, AI Workspace services, reverse proxy,
persistent target directories, and the Observability Agent. Do not copy the
old runtime or whole configuration directories.

QMD memory is persistent business data and requires a separate migration:

1. Discover the real source storage backend, schema/model version, indexes,
   attachments, metadata, caches, and background writers without assuming a
   path or database engine.
2. Produce a consistent read-only snapshot/export and record version, count,
   size, timestamp, and checksums without exposing memory content or secrets.
3. Restore into an isolated target and rebuild derived indexes or embeddings.
4. Compare workspace, thread, document, memory, attachment, timestamp, tag,
   and reference counts.
5. Test representative keyword, semantic, and cross-session memory queries.
6. Rehearse rollback by discarding and restoring the isolated target again.
7. Perform the final read-only sync or an approved short write-freeze when the
   backend cannot provide a consistent incremental export.
8. Switch xworkmate-bridge/QMD to the new target, observe, and roll back to the
   old source on failure.

Do not delete the old QMD data.

### C4 Agent Proxy: five-region deployment matrix

Tracking issue: [#839](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/839).

- JP/US/SG are new Akamai Terraform nodes.
- TW/PH are Ulighthost `existing` nodes loaded from Vault inventory.
- Deploy Caddy, Agent Proxy, exporter, and Observability Agent.
- Validate regional domains, TLS, connectivity, environment isolation, and
  UAT Accounts heartbeats.

TW/PH must never enter an Akamai Terraform state.

## Stage D: cutover and acceptance

Before any final cutover:

- all six Terraform plans are 0/0/0;
- SSH, HTTPS, reboot recovery, and monitoring are healthy;
- Web SaaS passes standard deployment and end-to-end checks;
- AI Workspace and QMD pass count, integrity, reference, attachment, and
  semantic-query checks;
- Vault and Observability pass backup, restore, integrity, and regression
  checks;
- JP/US/SG/TW/PH heartbeats and regional connectivity pass;
- DNS/entrypoint changes have an approved rollback procedure and observation
  window;
- before/after evidence shows the protected source is unchanged.

Any failed gate stops cutover and cleanup.

## Stage E: controlled cleanup

Cleanup is a separate, explicit approval. A successful deployment or migration
must not trigger cleanup automatically.

Eligible, one namespace at a time:

```text
web-saas
ai-workspace
agent-proxy-jp
agent-proxy-us
agent-proxy-sg
```

Permanently excluded:

```text
open-platform
the original observability.svc.plus node
TW/PH Ulighthost existing nodes
```

The legacy `selfhost` state is currently absent. If another historical key is
found, inventory it read-only, create a verified backup, map every resource
one-to-one, and obtain separate approval before archival. Never run a blind
`terraform state rm` or delete an S3 state object.

## Code-agent operating protocol

Every agent must follow this sequence:

1. Read this document and the linked issue for its assigned work package.
2. Inspect current `main` in all affected repositories; never rely on an old
   worktree or conversation summary as the source of truth.
3. State whether the action is read-only, code-only, plan, apply, migration,
   cutover, or cleanup.
4. Stop when the requested authority does not cover the next class of action.
5. Keep credentials out of Git, logs, plans, artifacts, issues, and comments.
6. Submit code changes through a PR and wait for required checks.
7. Record workflow run URLs, commit SHAs, state keys, resource IDs, acceptance
   evidence, and rollback results in the tracking issue.
8. Never combine multiple namespace applies or destroys into one approval.
9. Never infer permission to mutate the protected source.

Current authorization state: documentation and planning only.
