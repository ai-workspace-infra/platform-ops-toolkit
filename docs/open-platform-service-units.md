# Open Platform service units

`open-platform` remains one permanent Terraform namespace/state, but its
business services are independently deployable through
`selfhost-orchestrator.yml`.

| `open_platform_service` | Service | Playbook | Public endpoint |
| --- | --- | --- | --- |
| `vault` | Vault | `deploy_vault_domain.yml` | `vault.svc.plus` |
| `iam` | Zitadel | `deploy_iam_domain.yml` | `iam.svc.plus` |
| `observability` | Grafana/VictoriaMetrics | `deploy_observability_domain.yml` | `observability.svc.plus` |
| `all` | All three, in dependency order | `setup-open-platform-domain.yml` | all above |

## Dispatch contract

Use the existing Selfhost Orchestrator with:

```text
target_domains=open-platform
open_platform_service=all|vault|iam|observability
operation=deploy
dns_mode=none
```

`all` runs Vault first, then IAM and Observability. A single service can be
rerun after the foundation is available. The service selector changes the
Ansible playbook only; it does not create another Terraform state.

The legacy `observability.svc.plus` host is a migration source and is never
managed by these playbooks or added to the new `open-platform` state.

## Deployment-only mode

UAT Akamai `open-platform` deployment sets `OPEN_PLATFORM_DEPLOY_ONLY=true`.
For a fresh IAM node this allows the service to start before the
environment-scoped IAM secret has been migrated. The role generates a
one-time initial password unless `ZITADEL_ADMIN_PASSWORD` is explicitly
provided. Normal UAT/PROD deployments remain strict and require:

```text
kv/data/<env>/iam
  zitadel-admin@zitadel.iam.svc.plus
```

Business migration and DNS cutover remain separate operations.
