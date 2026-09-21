# UAT Akamai Cloud Selfhost Profile

UAT Akamai resources are managed through six independent Terraform namespaces.
Do not dispatch an aggregate `all`, `selfhost`, or generic `agent-proxy` operation.
The workflow defaults to `web-saas`; select exactly one namespace per run.

| Namespace | Workload | GitOps declaration | State suffix |
| --- | --- | --- | --- |
| `web-saas` | `console-selfhost-uat.onwalk.net` full stack | `resources/svc.plus/uat/akamai/web-saas.yaml` | `web-saas` |
| `open-platform` | New permanent host for `observability.svc.plus` and `vault.svc.plus` | `resources/svc.plus/uat/akamai/open-platform.yaml` | `open-platform` |
| `ai-workspace` | `xworkmate-bridge` and AI Workspace suite; `sg-sin-2`, `g8-dedicated-8-4` (4C8G) | `resources/svc.plus/uat/akamai/ai-workspace.yaml` | `ai-workspace` |
| `agent-proxy-jp` | JP Agent Proxy | `resources/svc.plus/uat/akamai/agent-proxy-jp.yaml` | `agent-proxy-jp` |
| `agent-proxy-us` | US Agent Proxy | `resources/svc.plus/uat/akamai/agent-proxy-us.yaml` | `agent-proxy-us` |
| `agent-proxy-sg` | SG Agent Proxy | `resources/svc.plus/uat/akamai/agent-proxy-sg.yaml` | `agent-proxy-sg` |

The canonical state key for each row is:

```text
terraform/uat/platform-ops-toolkit/akamai-cloud/manbuzhe2026/<namespace>/terraform.tfstate
```

JP/US/SG Akamai Agent Proxy resources each have a one-host manifest and state.
TW/PH remain Ulighthost `existing` inventory nodes; they are never created or
destroyed through Terraform.

## Dispatch

For a plan, select one of the six namespace names as `target_domains`, set
`vault_env_path=uat`, `cloud_provider=akamai-cloud`, and
`cloud_account=manbuzhe2026`. The route rejects aggregate selections. The
`open-platform` namespace is permanent and normal destroy is rejected. Destruction
of any other namespace is fail-closed until the migration acceptance gates and
state-scope checks described in [the split migration runbook](uat-split-selfhost-migration.md)
pass. Never use `selfhost` as a shared state.

## Migration-source boundary

The existing `ssh ubuntu@observability.svc.plus` all-in-one host is an external
migration source and rollback point. It is not an Akamai resource: do not import it,
add it to Terraform state, modify it, or include it in any destroy scope. Keep it
unchanged until the new Open Platform services pass the documented health gates and
the controlled cutover is accepted. It is not automatically destroyed afterward.

## Credentials

Akamai Cloud uses the `linode/linode` provider. `LINODE_TOKEN` is injected at runtime
through Vault/OIDC. GitOps declarations contain only non-secret resource settings
and public SSH keys; never commit API tokens, passwords, or private keys.
