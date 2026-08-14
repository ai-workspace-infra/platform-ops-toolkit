# platform-ops-toolkit

[🇬🇧 English](README.md) · [🇨🇳 中文版](README_zh.md) · [English alternate](README_EN.md)

## Start here: the actual operation entry point

If you are using this repository for the first time, follow these four steps:

1. Prepare a Vault server reachable from the GitHub Actions runner. The current default is [`https://vault.svc.plus`](https://vault.svc.plus).
2. Use a Vault administrator token to run [`scripts/create_vault_service_repo_roles.sh`](scripts/create_vault_service_repo_roles.sh) and configure GitHub Actions OIDC → Vault JWT.
3. Open **Actions → Deploy Environment & Provision Infrastructure → Run workflow** in this repository.
4. Fill in the target environment and deployment inputs, then click **Run workflow**. This is the entry point for deployment, resize, migration, backup, and restore operations.

The entry workflow is:

```text
.github/workflows/platform-ops.yaml
```

This is an **orchestration repository**, not the home of every configuration file. The three core configuration repositories are:

| Repository | Responsibility | When to change it |
| --- | --- | --- |
| [`platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | GitHub Actions entry points, orchestration, inputs, and shared operations scripts | Start a task or change workflow behavior |
| [`playbooks`](https://github.com/ai-workspace-infra/playbooks) | Ansible Playbooks, OS initialization, and reusable domain CD workflows | Change host configuration, application installation, or deployment logic |
| [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) | Terraform modules, cloud resources, hosts, and environment resource declarations | Create or change cloud resources, VPSs, networks, or Terraform |
| [`gitops`](https://github.com/ai-workspace-infra/gitops) | Environment runtime configuration and GitOps desired state | Change domains, service settings, image tags, or environment configuration |
| [`artifacts`](https://github.com/ai-workspace-infra/artifacts) | Optional images, archives, build artifacts, and release manifests | Use only when a release needs to reuse or trace artifacts |

The short version is: `platform-ops-toolkit` is the button, `iac_modules` builds resources, `playbooks` installs and configures applications, and `gitops` declares the desired environment state.

## First-time setup

### 1. Prepare Vault

GitHub Actions does not store cloud credentials, SSH private keys, or application secrets directly in workflow inputs. Vault must be initialized, unsealed, and reachable from the runner.

The default address is [`https://vault.svc.plus`](https://vault.svc.plus). A manual workflow run can override it with `vault_addr`.

### 2. Configure GitHub Actions OIDC → Vault JWT

This is a one-time setup and requires Vault administrator access:

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # Vault administrator token

chmod +x scripts/create_vault_service_repo_roles.sh
./scripts/create_vault_service_repo_roles.sh
```

For the detailed JWT auth, Role/Policy, workflow claim, KV isolation, and troubleshooting instructions, see [Vault Authentication and Policy Isolation](docs/vault/vault_authentication_and_policy_isolation.md). This README only provides the onboarding path and operation entry points.

Verify the result:

```bash
./scripts/vault/vault_layout_verify.py
```

Exit code `0` means the assertions passed. Never commit `VAULT_TOKEN` or put it into a workflow input.

#### 2.1 Roles and permissions created by the script

The script creates three environment policies and six JWT roles. The two role families share the same environment policy but have different workflow allowlists:

| Role | Policy | Allowed workflows | Ref boundary |
| --- | --- | --- | --- |
| `github-actions-platform-ops-toolkit-sit` | `...-sit` | Toolkit workflow allowlist | PR merge refs and any branch |
| `github-actions-platform-ops-toolkit-uat` | `...-uat` | Toolkit workflow allowlist | `main`, `release/*`, `bugfix/*`, `daily-build-*` |
| `github-actions-platform-ops-toolkit-prod` | `...-prod` | Toolkit workflow allowlist | `main`, `v*` tags |
| `github-actions-playbooks-sit` | `...-sit` | Playbooks domain-CD allowlist | PR merge refs and any branch |
| `github-actions-playbooks-uat` | `...-uat` | Playbooks domain-CD allowlist | `main`, `release/*`, `bugfix/*`, `daily-build-*` |
| `github-actions-playbooks-prod` | `...-prod` | Playbooks domain-CD allowlist | `main`, `v*` tags |

Every role is bound to `repository`, `job_workflow_ref`, and Git ref. Adding a new workflow does not automatically grant it Vault access.

KV permission summary:

| KV path | `sit` / `uat` | `prod` |
| --- | --- | --- |
| `kv/data/CICD`, `kv/data/openclaw`, `kv/data/action-runner` | `read` | `read` |
| `kv/data/CICD/domains/*` | `create/read/update/list` | `create/read/update/list` |
| `kv/data/CICD/<env>` | Read-only for its own environment | Read-only for its own environment |
| `kv/data/<env>/*` | `create/read/update/delete/list` | `create/read/update/list`; no delete |
| `kv/metadata/<env>/*` | `list/read/delete` | `list/read`; no delete |

The current script allows the `prod` role on `main` and `v*` tags. If production must be tag-only, change the script itself.

### 3. Populate Vault KV

The workflow mainly reads three KV tiers after authentication:

| Type | Path | Examples |
| --- | --- | --- |
| Shared CI credentials | `kv/data/CICD` | GHCR and shared runtime credentials |
| Environment base credentials | `kv/data/CICD/<env>` | `VULTR_API_KEY`, Terraform state, SSH key |
| Environment application secrets | `kv/data/<env>/*` | Database, Billing, and agent-proxy secrets |

`<env>` is `sit`, `uat`, or `prod`. Production secrets should not be deleted or rotated by an ordinary deployment workflow.

### 4. Run from the Actions page

Open **Actions → Deploy Environment & Provision Infrastructure → Run workflow**.

Recommended first-run inputs:

| Input | Recommendation |
| --- | --- |
| `runner_type` | `ubuntu-latest` |
| `deploy_tag` | An existing immutable image version, such as `daily-build-2026.07.30-r1` |
| `infra_ref` / `playbooks_ref` / `gitops_ref` | Matching `main` or release refs across the three core repositories |
| `target_domains` | Start with one domain; do not start with `all` |
| `cloud_provider` | `vultr-vps`; this is the only end-to-end provider currently wired for the business domains |
| `vault_env_path` | Match the target environment: `sit`, `uat`, or `prod` |
| `run_infrastructure` | Enable when hosts or infrastructure must be created or updated |
| `run_application_deploy` | Enable for application deployment; infrastructure must also be enabled |
| `run_full_stack` | Use when creating an environment from scratch; it enables infrastructure, application, and DNS steps |

For the first validation, run infrastructure and inspect the CMDB before deploying applications. Do not enable `confirm_dns_switch` during testing.

## Other workflow entry points

| Workflow | Purpose | Entry and caution |
| --- | --- | --- |
| [`data-migration.yaml`](.github/workflows/data-migration.yaml) | Data migration, backup, and restore | Called by the main workflow or run manually; keep `accounts_dry_run=true` on the first run |
| [`daily-main-snapshot.yaml`](.github/workflows/daily-main-snapshot.yaml) | Creates a `daily-build-*` tag across organizations and repositories and triggers builds | Scheduled or manual; use the resulting tag as `deploy_tag` |
| [`k6-performance-test.yaml`](.github/workflows/k6-performance-test.yaml) | k6 load testing and observability metrics | Manual; start with `smoke`, then increase VUs |
| [`cron-rotate-domain-tls-certs.yaml`](.github/workflows/cron-rotate-domain-tls-certs.yaml) | Rotates domain TLS certificates and stores them in Vault | Scheduled every two months or manual; requires Cloudflare credentials |

### Special GitHub App permissions for `daily-main-snapshot.yaml`

The workflow's top-level `permissions:` controls only the default `GITHUB_TOKEN`; it does not provide cross-organization access. The workflow reads the App private key from Vault, creates an installation token for each organization, and uses `GH_TOKEN` to list repositories, create tags, dispatch builds, inspect workflow runs, and read release assets.

Required configuration:

- Install the same GitHub App in every matrix organization: `ai-workspace-infra`, `ai-workspace-lab`, `ai-workspace-services`, and `ai-workspace-xstream`.
- Grant the installation access to target repositories; prefer selected repositories to reduce scope.
- Grant at least `Contents: Read and write` and `Actions: Read and write`.
- Store the App private key as `app_private_key` at `kv/data/CICD/github-app/daily-snapshot`.
- Keep `owner: matrix.organization` aligned with the App installation account.

Official references: [GitHub App in Actions](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow), [choosing GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app), and [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token).

## Trigger routes and execution flow

| Trigger | Default environment | Meaning |
| --- | --- | --- |
| Pull Request | `sit` | Validation and planning; not a production release path |
| Push to `main` / `release/*` | `uat` | Validation and planning |
| `v*` tag | `prod` | Production release path |
| `workflow_dispatch` | Manually selected | Actually runs provision, deploy, migration, backup, restore, and related actions |

The main deployment flow is:

```text
platform-ops-toolkit
  → OIDC authentication to Vault
  → iac_modules / Terraform creates resources and produces the CMDB
  → playbooks / Ansible deploys applications using that CMDB
  → gitops supplies or receives the desired environment configuration
```

## Adapting it to a personal project

The current workflow is orchestrated for `ai-workspace-infra`. `web-saas`, `ai-workspace`, `agent-proxy`, and `infra-platform` are project-specific domains, not generic modules.

When switching projects, update at least:

1. The `ai-workspace-infra/iac_modules`, `playbooks`, `gitops`, and every reusable workflow `uses:` reference in `.github/workflows/platform-ops.yaml`.
2. Service repositories, image registries, domains, and tags referenced inside `playbooks` and GitOps.
3. `target_domains`, the Terraform host/resource matrix, job conditions, and Vault paths; remove domains that do not exist in the personal project.
4. GitHub App installations, selected repositories, Contents/Actions permissions, and GitOps write access.
5. `REPO`, `PLAYBOOKS_REPO`, workflow allowlists, and new policies/roles in [`vault_auth_split.sh`](scripts/create_vault_service_repo_roles.sh).

Search for old project bindings with:

```bash
rg -n 'ai-workspace-infra|ai-workspace-xstream|compassvpn|svc\.plus|onwalk\.net' \
  .github docs config scripts
```

## Troubleshooting

### Which repository should I change?

Change `iac_modules` for cloud resources, `playbooks` for hosts and application deployment, and `gitops` for desired environment state. Change this repository only for entry parameters and orchestration.

### Where is “Run workflow”?

Open this repository's **Actions** tab, select **Deploy Environment & Provision Infrastructure**, and click **Run workflow**. You need Actions permission, and the workflow must contain `workflow_dispatch`.

### Why does Vault return 403?

Check the Vault address, JWT auth, the role's repository/ref/workflow claims, KV paths, and `vault_env_path`. Then run `vault_layout_verify.py`.

### Why does AWS/GCP/Azure fail?

Those are reserved multi-cloud options. The business-domain delivery path is currently wired end-to-end only for `vultr-vps`.

## Further reading

- [Vault Authentication and Policy Isolation](docs/vault/vault_authentication_and_policy_isolation.md)
- [Vault KV tier model](docs/vault/kv_tier_model.md)
- [Multi-environment delivery standard](docs/standards/multi-environment-delivery-and-release-standard.md)
- [Business domain documentation](docs/domains/README.md)
- [Entry workflow](.github/workflows/platform-ops.yaml)
