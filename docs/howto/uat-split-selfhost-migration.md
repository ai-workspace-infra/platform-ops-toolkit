# UAT split Selfhost deployment and migration runbook

This runbook describes the isolated UAT workloads and the safe migration boundary.
It does not authorize deployment, data copy, DNS changes, or retirement of the
existing `observability.svc.plus` host.

## Workload map

| Workload | UAT responsibility | Provisioning boundary |
| --- | --- | --- |
| `web-saas` | Full Selfhost stack at `console-selfhost-uat.onwalk.net` (Console, Accounts, Billing, PostgreSQL and supporting services) | Independent Terraform namespace/state |
| `open-platform` | New normalized, permanent node for `observability.svc.plus` and `vault.svc.plus` | Independent, retained Terraform namespace/state |
| `ai-workspace` | Full AI Workspace suite, including `xworkmate-bridge` and its ACP/runtime components | Independent Terraform namespace/state; fixed at `sg-sin-2` / `g8-dedicated-8-4` (4C8G) |
| `agent-proxy-jp` | JP Agent Proxy | Independent Terraform namespace/state |
| `agent-proxy-us` | US Agent Proxy | Independent Terraform namespace/state |
| `agent-proxy-sg` | SG Agent Proxy | Independent Terraform namespace/state |

TW/PH must remain `management_mode: existing`, `provisioner: ansible`, and
`lifecycle: external`. They are never Terraform create/destroy targets.

The six Akamai UAT namespaces are exactly:

```text
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/web-saas/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/open-platform/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/ai-workspace/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/agent-proxy-jp/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/agent-proxy-us/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/agent-proxy-sg/terraform.tfstate
```

Do not use a shared `selfhost`, `all`, or generic `agent-proxy` state for UAT
Akamai. Dispatch one namespace per run. The UAT Akamai router rejects aggregate
targets, and the standalone Akamai IaC workflow accepts only the six canonical
manifest/workspace pairs.

## Open Platform migration stages

The current `ssh ubuntu@observability.svc.plus` host is the all-in-one source and
rollback point. Keep its host, user, services, DNS and Terraform management
boundary unchanged throughout migration and acceptance. Do not point the source
host at the new node, run provisioning against it, add it to a Terraform
manifest/state, or automatically retire it.

1. **Inventory and backup** — record service versions, data locations, ownership,
   database topology, Vault storage/seal requirements, certificates, Caddy
   routes, and DNS. Take application-consistent backups and record their
   immutable location/checksum. Do not put secret values in the run log.
2. **Deploy the new target** — provision only the `open-platform` manifest/state;
   bootstrap services on the new normalized node. Do not include the old source
   in any target list or destroy plan.
3. **Synchronize data** — restore/copy from verified backups and perform an
   explicitly reviewed final delta sync. Keep one writer per stateful service;
   do not start competing Vault/PostgreSQL writers.
4. **Dual-end health validation** — verify the old source and new target
   independently, including Vault seal/health, observability ingestion/query,
   Caddy TLS/host routing, and representative application reads. The source must
   remain healthy and unchanged as the rollback endpoint.
5. **Gated cutover** — require an operator approval, backup reference, successful
   target and source health evidence, and a rehearsed DNS rollback to the source.
   Switch only `vault.svc.plus` / `observability.svc.plus` after those gates pass;
   immediately re-check both public names and service-level health. If a check
   fails, restore the recorded pre-cutover DNS values to the source and verify
   recovery there.

After acceptance, the new `open-platform` node is a permanent resource that
continues hosting `observability.svc.plus` and `vault.svc.plus`. Old-node
retirement is outside this runbook and must be a separate, explicit future
change after a stable acceptance window. There is no automated source destroy
step; the old `observability.svc.plus` source is never imported into Akamai
Terraform state or destroy scope.

## Destruction guard

The Akamai destroy preflight allows only one of the five cleanup namespaces:
`web-saas`, `ai-workspace`, `agent-proxy-jp`, `agent-proxy-us`, or
`agent-proxy-sg`. It always rejects `open-platform`, `selfhost`, and `all`.
Before any of the five may be cleaned, update
`config/open-platform-uat-cleanup-acceptance.json` in a reviewed PR with the
migration-complete flag, unchanged-source-through-acceptance assertion, both
health gates, state-isolation verification, and non-empty backup/acceptance
references. It is intentionally pending by default, so cleanup currently fails
closed.

The six namespace keys listed above are the only supported state layout. The
`open-platform` key is permanent; the other five are independently disposable
after acceptance. A shared `selfhost` state is not supported. The guard compares every
managed `linode_instance` label to the selected profile manifest; unlabelled or
out-of-profile resources fail closed. `observability.svc.plus` is a protected
external source label by default. The source also cannot be captured through an
aggregate manifest because aggregate Akamai UAT routing is rejected.

Cleanup sequence is permitted only after all are true: the new Open Platform
migration is accepted; target and source health checks passed; the old source
was unchanged through acceptance; all six namespaces have been verified
distinct and `open-platform` is absent from each cleanup manifest/state; the
backup and rollback references are recorded. Then destroy each of the five
non-permanent namespaces separately. Never run a workspace-wide or `all`
destroy.

Run local contract checks without cloud credentials or cloud API access:

```bash
bash .github/scripts/tests/platform_ops_akamai_destroy_scope_contract_test.sh
bash .github/scripts/tests/platform_ops_uat_six_namespace_contract_test.sh
python3 -m unittest .github.scripts.tests.test_platform_ops_destroy_scope
```

## Domain separation

UAT Selfhost Caddy names must come from UAT CMDB/service-domain facts. Never copy
PROD hostnames into UAT inventory or workflows. The source names
`observability.svc.plus` and `vault.svc.plus` are shared service identities, but
their new target routing remains unchanged until the gated cutover stage.
