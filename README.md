# platform-ops-toolkit

[🇬🇧 English](README.md) · [🇨🇳 中文版](README_zh.md)

`platform-ops-toolkit` is the **entry repository** for platform operations. It is not the place where every infrastructure configuration is stored.

The three core configuration repositories are:

| Repository | Responsibility | When to use it |
| --- | --- | --- |
| [`platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | Entry Actions, workflow orchestration, inputs, and shared operations scripts | Start an operations task or change pipeline behavior |
| [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) | Terraform modules, cloud resources, hosts, and environment resource declarations | Create or change cloud resources, VPSs, networks, or Terraform configuration |
| [`playbooks`](https://github.com/ai-workspace-infra/playbooks) | Ansible Playbooks and reusable domain deployment workflows | Change OS initialization, application installation, or deployment logic |
| [`gitops`](https://github.com/ai-workspace-infra/gitops) | GitOps environment configuration and desired runtime state | Change environment parameters, domains, service settings, or deployment tags |
| [`artifacts`](https://github.com/ai-workspace-infra/artifacts) | Optional build artifacts, images, archives, or release manifests | Use only when a release needs to reuse or trace build artifacts |

`artifacts` is optional. The platform operations entry point can be used without it when the required images or immutable `deploy_tag` already exist elsewhere.

## New user guide

### 0. Decide where your change belongs

- To understand the flow, read this file and [`platform-ops.yaml`](.github/workflows/platform-ops.yaml).
- To change cloud resources, use `iac_modules`.
- To change server or application installation, use `playbooks`.
- To change environment runtime configuration, use `gitops`.
- To inspect or manage build artifacts, use `artifacts` only if the project needs it.
- To run a deployment, resize, migration, backup, or restore, return to this repository's **Actions** page.

Do not copy the three core repositories' configuration into this repository. The entry workflow checks them out using the selected refs.

### 1. Prepare a Vault server

GitHub Actions does not store cloud credentials, SSH private keys, or application secrets directly in workflow inputs. Prepare a Vault server that is initialized, unsealed, and reachable from the GitHub Actions runner.

The current default address is [`https://vault.svc.plus`](https://vault.svc.plus). A manual workflow run can override it with `vault_addr`.

For detailed GitHub Actions OIDC → Vault JWT setup—including JWT auth, Role/Policy binding, workflow claims, KV isolation, and troubleshooting—see [Vault Authentication and Policy Isolation](docs/vault/vault_authentication_and_policy_isolation.md). This README only provides the onboarding summary and entry points.

### 2. Configure GitHub Actions OIDC → Vault JWT

This is a one-time setup and requires a Vault administrator token. The script creates environment-specific policies and JWT roles for `sit`, `uat`, and `prod`, with repository, workflow, and ref restrictions.

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # Vault administrator token

chmod +x docs/tasks/vault_auth_split.sh
./docs/tasks/vault_auth_split.sh
```

Verify the layout after initialization:

```bash
./scripts/vault/vault_layout_verify.py
```

Exit code `0` means the assertions passed. Never commit `VAULT_TOKEN` or put it into a workflow input.

#### 2.1 Roles and permissions created by the script

`vault_auth_split.sh` creates three environment policies and six JWT roles. The two role families use the same environment policy, but their `job_workflow_ref` allowlists target the platform toolkit workflows and the Playbooks reusable workflows respectively.

| Role | Policy | Allowed workflow source | Branch / tag boundary | Token constraints |
| --- | --- | --- | --- | --- |
| `github-actions-platform-ops-toolkit-sit` | `github-actions-platform-ops-toolkit-sit` | Platform toolkit allowlist | PR merge refs and any branch | Batch token, 1h TTL, no default policy |
| `github-actions-platform-ops-toolkit-uat` | `github-actions-platform-ops-toolkit-uat` | Platform toolkit allowlist | `main`, `release/*`, `bugfix/*`, and `daily-build-*` branches/tags | Same |
| `github-actions-platform-ops-toolkit-prod` | `github-actions-platform-ops-toolkit-prod` | Platform toolkit allowlist | `main` and `v*` tags | Same |
| `github-actions-playbooks-sit` | `github-actions-platform-ops-toolkit-sit` | Playbooks domain-CD allowlist | PR merge refs and any branch | Same |
| `github-actions-playbooks-uat` | `github-actions-platform-ops-toolkit-uat` | Playbooks domain-CD allowlist | `main`, `release/*`, `bugfix/*`, and `daily-build-*` branches/tags | Same |
| `github-actions-playbooks-prod` | `github-actions-platform-ops-toolkit-prod` | Playbooks domain-CD allowlist | `main` and `v*` tags | Same |

Every role is bound to the calling repository, an allowlisted `job_workflow_ref`, and an allowed Git ref. Adding a new workflow to the repository does not automatically grant it Vault access.

The actual KV permissions are:

| KV path | `sit` / `uat` | `prod` | Description |
| --- | --- | --- | --- |
| `kv/data/CICD`, `kv/data/openclaw`, `kv/data/action-runner` | `read` | `read` | Shared CI and runtime credentials; read-only |
| `kv/metadata/CICD`, `kv/metadata/action-runner` | `list`, `read` | `list`, `read` | Metadata inspection only; no deletion |
| `kv/data/CICD/github-app/daily-snapshot`, `kv/data/CICD/observability` | `read` | `read` | Snapshot and observability credentials |
| `kv/data/CICD/domains/*` | `create`, `read`, `update`, `list` | `create`, `read`, `update`, `list` | Shared domain certificates; update is intentional, deletion is denied |
| `kv/metadata/CICD/domains/*` | `list`, `read` | `list`, `read` | Certificate metadata; deletion is denied |
| `kv/data/CICD/<env>` | `read` | `read` | Environment cloud credentials, Terraform state, and SSH key; read-only |
| `kv/metadata/CICD/<env>` | `list`, `read` | `list`, `read` | Metadata for environment base credentials |
| `kv/data/WEB_SAAS` | `read` (not granted to current `sit`) | `read` | Compatibility path; currently shared by UAT and prod |
| `kv/data/<env>/*` | `create`, `read`, `update`, `delete`, `list` | `create`, `read`, `update`, `list` | Environment-specific application secrets; prod denies data deletion |
| `kv/metadata/<env>/*` | `list`, `read`, `delete` | `list`, `read` | Prod denies metadata deletion to prevent permanent version removal |

The script currently allows the `prod` role on `main` and `v*` tags. If production must be tag-only, tighten the prod `ref` in the script as well; changing the README is not a security control.

### 3. Populate required Vault data

The workflow reads these KV tiers after authenticating:

| Type | Example path | Purpose |
| --- | --- | --- |
| Shared CI credentials | `kv/data/CICD` | Shared services such as container registry access |
| Environment base credentials | `kv/data/CICD/<env>` | `VULTR_API_KEY`, Terraform state, and SSH deployment key |
| Environment application secrets | `kv/data/<env>/*` | Database, Billing, proxy, and other service secrets |

`<env>` is `sit`, `uat`, or `prod`. The production role cannot delete KV metadata; production secret rotation should be handled by an administrator or a dedicated rotation workflow.

### 4. Start the entry workflow from Actions

Open **Actions → Deploy Environment & Provision Infrastructure → Run workflow** in this repository.

The entry file is:

```text
.github/workflows/platform-ops.yaml
```

For a first run, use these defaults as a starting point:

| Input | Recommendation |
| --- | --- |
| `runner_type` | `ubuntu-latest` |
| `deploy_tag` | An existing immutable image version, such as `daily-build-2026.07.30-r1` |
| `infra_ref` / `playbooks_ref` / `gitops_ref` | Matching `main` or release refs across the three repositories |
| `toolkit_ref` | The matching toolkit ref; blank defaults to `main` |
| `target_domains` | Start with one required domain instead of `all` |
| `cloud_provider` | `vultr-vps`; this is the only end-to-end provider currently wired for these domains |
| `vault_env_path` | Match the target environment: `sit`, `uat`, or `prod` |
| `run_infrastructure` | Enable when hosts or infrastructure must be created or updated |
| `run_application_deploy` | Enable for application deployment; it requires `run_infrastructure` |
| `run_full_stack` | Use when creating an environment from scratch; it also enables application and DNS steps |

For a first validation, run infrastructure first, verify the hosts and CMDB, and then run application deployment. Do not enable `confirm_dns_switch` during testing.

## Other Actions entry points

The repository also contains four workflows for focused operations:

| Workflow | Purpose | How to use it |
| --- | --- | --- |
| [`data-migration.yaml`](.github/workflows/data-migration.yaml) | Data migration, backup, and restore; supports accounts migration and domain-driven site migration | It can be called by `platform-ops.yaml` or run manually. Keep `accounts_dry_run=true` for the first run |
| [`daily-main-snapshot.yaml`](.github/workflows/daily-main-snapshot.yaml) | Creates a consistent `daily-build-*` snapshot tag across organizations and repositories, then triggers build/release workflows | Runs on schedule or manually; the resulting tag can be used as `deploy_tag` |
| [`k6-performance-test.yaml`](.github/workflows/k6-performance-test.yaml) | Runs k6 load tests and sends metrics to the observability system | Manual only; start with `smoke`, then increase to `capacity` or higher VU counts |
| [`cron-rotate-domain-tls-certs.yaml`](.github/workflows/cron-rotate-domain-tls-certs.yaml) | Rotates domain TLS certificates and stores the certificate state in Vault | Runs every two months or manually; requires Cloudflare credentials in Vault and production approval |

The relationship is:

```text
daily-main-snapshot.yaml  → create a cross-repository deploy_tag
                                ↓
platform-ops.yaml         → provision resources + deploy applications
                                ↓
data-migration.yaml       → migrate / backup / restore when needed
k6-performance-test.yaml  → validate performance after deployment
cron-rotate-domain-tls-certs.yaml → independent certificate maintenance
```

## Trigger routes and environments

| Trigger | Default environment | Behavior |
| --- | --- | --- |
| Pull Request | `sit` | Validation and planning; not a production release path |
| Push to `main` / `release/*` | `uat` | Validation and planning |
| `v*` tag | `prod` | Production release path; production role accepts the corresponding ref boundary |
| `workflow_dispatch` | Manually selected | Runs provision, deploy, migration, backup, restore, and related actions |

The business-domain delivery path is currently wired end-to-end for `vultr-vps`. AWS, GCP, and Azure modules exist in `iac_modules`, but the presence of an option does not mean `platform-ops.yaml` supports that provider for these domains.

## What happens during a run

```text
Run workflow
    ↓
platform-ops-toolkit reads inputs and authenticates to Vault with OIDC
    ↓
iac_modules runs Terraform, creates/updates resources, and produces the CMDB
    ↓
playbooks uses the CMDB from this run for Ansible deployment
    ↓
gitops supplies the desired environment state and may receive an automated tag update
    ↓
GitHub Actions reports logs, deployment results, and follow-up checks
```

Terraform prepares the resources first. Ansible then uses the inventory generated by that same run; do not deploy with an old inventory.

## Adapting the workflow to a personal project

`.github/workflows/platform-ops.yaml` is currently orchestrated for the `ai-workspace-infra` project. `web-saas`, `ai-workspace`, `agent-proxy`, and `infra-platform` represent this project's real systems; they are not generic modules.

| Current binding | What to change in a personal project |
| --- | --- |
| `ai-workspace-infra/iac_modules` | Replace with the project's Terraform/IAC repository and preserve the required directories, resource declarations, and outputs |
| `ai-workspace-infra/playbooks` | Replace with the project's Ansible and reusable domain-CD workflow repository |
| `ai-workspace-infra/gitops` | Replace with the project's GitOps repository; add write access if automatic tag updates are retained |
| `ai-workspace-infra/playbooks/.github/workflows/web-saas-domain-cd.yaml@main` | Replace every reusable domain workflow reference, including AI Workspace, Agent Proxy, and Open Platform |
| `ai-workspace-xstream/xray-exporter`, `compassvpn/xray-exporter` | Replace with the project's exporter repository or pass `xray_exporter_release_repository` explicitly |
| `artifacts` | Integrate only if the personal project needs a shared artifact source |

Recommended migration steps:

1. Prepare the personal project's `platform-ops-toolkit`, `iac_modules`, `playbooks`, and `gitops` repositories. They may have different names, but their interfaces and responsibilities must match. `artifacts` remains optional.
2. Replace hard-coded repositories and owners in `.github/workflows/platform-ops.yaml`, especially:

   ```text
   repository: ai-workspace-infra/iac_modules
   repository: ai-workspace-infra/playbooks
   repository: ai-workspace-infra/gitops
   uses: ai-workspace-infra/playbooks/.github/workflows/...@main
   owner: ai-workspace-infra
   ```

   Reusable workflow `uses:` references must be changed as well as checkout steps. The target workflows must keep compatible `workflow_call` inputs and secrets.
3. Remove or adapt domains that do not exist in the personal project. Update `target_domains`, the Terraform host/resource matrix, job `if` conditions, Vault paths, and the corresponding Playbooks domain workflows.
4. Check application repository references inside `playbooks` and GitOps. The toolkit dispatches domain workflows; the service repository, image registry, deploy tag, and domain names are often defined in those repositories.
5. Configure GitHub permissions. The toolkit must read the IAC, Playbooks, and GitOps repositories. Reusable workflows must be visible to the caller. The GitOps update job needs write access; the current workflow uses a GitHub App token with `owner: ai-workspace-infra`, which must be reinstalled and changed or replaced with a minimal Vault-stored fine-grained token.
6. Recreate Vault roles and policies for the personal project. Update `REPO`, `PLAYBOOKS_REPO`, and the workflow allowlists in [`vault_auth_split.sh`](docs/tasks/vault_auth_split.sh). Bind `repository` and `job_workflow_ref` to the personal project; do not reuse the current project's role. Recreate the KV paths and run `vault_layout_verify.py`.
7. Use `workflow_dispatch` for a single-domain, non-production plan and deployment test before enabling `all` or production tag releases.

Search for remaining project-specific bindings with:

```bash
rg -n 'ai-workspace-infra|ai-workspace-xstream|compassvpn|svc\.plus|onwalk\.net' \
  .github docs config scripts
```

## Troubleshooting

### Which repository should I change?

Change `iac_modules` for cloud resources, `playbooks` for OS/application deployment, and `gitops` for environment desired state. Change this repository only for entry parameters, orchestration, or shared operations scripts.

### Why is “Run workflow” missing?

Confirm that you have Actions permission and that the workflow exists on the current branch. Only workflows with `workflow_dispatch` can be started from the Actions page.

### Why does Vault return 403 or permission denied?

Check `VAULT_ADDR`, the OIDC/JWT auth method, and whether the initialization script has been run. Confirm that `vault_env_path` matches the target environment and that production uses an allowed `v*` tag or `main` ref. Then run `./scripts/vault/vault_layout_verify.py`.

### Why does AWS/GCP/Azure fail?

Those are reserved multi-cloud options. The business-domain delivery path currently has only the `vultr-vps` end-to-end wiring and intentionally fails fast for the other providers.

### Why did deployment succeed but the application is wrong?

Check that `deploy_tag`, `playbooks_ref`, and `gitops_ref` describe the same release. Then check the target domain, Vault environment path, DNS, and GitOps configuration.

## Further reading

- [Vault authentication and policy isolation](docs/vault/vault_authentication_and_policy_isolation.md)
- [Vault KV tier model](docs/vault/kv_tier_model.md)
- [Multi-environment delivery standard](docs/standards/multi-environment-delivery-and-release-standard.md)
- [Business domain documentation](docs/domains/README.md)
- [Entry workflow](.github/workflows/platform-ops.yaml)
