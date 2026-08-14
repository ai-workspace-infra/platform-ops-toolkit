# platform-ops-toolkit — English guide

This file is the explicit English alternate entry point. The canonical English guide is [`README.md`](README.md); the Chinese guide is [`README_zh.md`](README_zh.md).

## Quick start

1. Prepare a reachable, initialized and unsealed Vault server. The default is [`https://vault.svc.plus`](https://vault.svc.plus).
2. From a checkout of this repository, run [`scripts/create_vault_service_repo_roles.sh`](scripts/create_vault_service_repo_roles.sh) with a Vault administrator token.
3. Verify the result with `./scripts/vault/vault_layout_verify.py`.
4. Open **Actions → Deploy Environment & Provision Infrastructure → Run workflow**.
5. Start with a single domain, matching refs, an immutable `deploy_tag`, `vultr-vps`, and the correct `vault_env_path`.

The workflow file that acts as the main entry point is [`.github/workflows/platform-ops.yaml`](.github/workflows/platform-ops.yaml).

## Repository map

| Repository | Role |
| --- | --- |
| [`platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | GitHub Actions entry point and orchestration |
| [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) | Terraform modules and cloud resources |
| [`playbooks`](https://github.com/ai-workspace-infra/playbooks) | Ansible OS/application configuration and reusable domain workflows |
| [`gitops`](https://github.com/ai-workspace-infra/gitops) | GitOps environment configuration and desired state |
| [`artifacts`](https://github.com/ai-workspace-infra/artifacts) | Optional images, archives, and release artifacts |

## Vault and permissions

The toolkit authenticates to Vault with GitHub Actions OIDC → Vault JWT. Detailed setup, claims, policies, roles, KV paths, and troubleshooting are documented in [Vault Authentication and Policy Isolation](docs/vault/vault_authentication_and_policy_isolation.md).

The initializer creates environment policies and two role families:

- `github-actions-platform-ops-toolkit-{sit,uat,prod}` for toolkit workflows.
- `github-actions-playbooks-{sit,uat,prod}` for reusable Playbooks workflows.

The roles are restricted by repository, `job_workflow_ref`, and Git ref. `sit` is for PR/branch validation, `uat` covers the configured UAT branches and snapshot refs, and `prod` currently allows `main` and `v*` tags. The production policy denies KV data and metadata deletion.

## Other operation workflows

- [`data-migration.yaml`](.github/workflows/data-migration.yaml): migration, backup, and restore.
- [`daily-main-snapshot.yaml`](.github/workflows/daily-main-snapshot.yaml): cross-organization snapshot tags and build triggers.
- [`k6-performance-test.yaml`](.github/workflows/k6-performance-test.yaml): k6 load testing.
- [`cron-rotate-domain-tls-certs.yaml`](.github/workflows/cron-rotate-domain-tls-certs.yaml): scheduled or manual TLS certificate rotation.

`daily-main-snapshot.yaml` uses a GitHub App installation token, not only the default `GITHUB_TOKEN`. Install the App in every matrix organization, grant access to the target repositories, and provide at least `Contents: Read and write` and `Actions: Read and write`. The App private key is read from `kv/data/CICD/github-app/daily-snapshot`.

Official references: [GitHub App in Actions](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow), [choosing GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app), and [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token).

## Personal project migration

The workflow is currently wired to `ai-workspace-infra`. To use it for a personal project, replace the hard-coded `iac_modules`, `playbooks`, `gitops`, and reusable workflow references; update service repositories, domains, registries, and GitOps settings; install the GitHub App in the new organizations; and recreate Vault roles and workflow allowlists with the new repository names.

Use this search to find remaining project-specific references:

```bash
rg -n 'ai-workspace-infra|ai-workspace-xstream|compassvpn|svc\.plus|onwalk\.net' \
  .github docs config scripts
```

For the full onboarding guide, parameters, execution flow, environment routing, and troubleshooting, continue to [README.md](README.md).
