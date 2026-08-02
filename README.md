# platform-ops-toolkit

[🇬🇧 English](README.md) | [🇨🇳 中文版](README_zh.md)

Welcome to **platform-ops-toolkit**. This repository is the platform operations control plane for the AI Workspace infrastructure. It covers the full lifecycle rather than backup alone:

- **Provisioning** — Terraform-based host provisioning, plus multi-cloud IaC pipelines for landing-zone baselines, account/VPC matrices, and resource matrices.
- **Deployment** — per-service Ansible delivery across four business domains, driven by a CMDB generated fresh on every run.
- **Multi-cloud, by design, unevenly wired today** — `iac_modules` already carries real Terraform modules for `aws-cloud` / `gcp-cloud` / `azure-cloud` / `vultr-vps`, and the landing-zone / account-matrix / resources-matrix pipelines use all four. The four business-domain pipelines below (`platform-ops.yaml`) are **Vultr-only today**: `cloud_provider` is a required input there so the target is always explicit, but selecting anything other than `vultr-vps` fails fast rather than quietly deploying to Vultr under a different provider's name. See [§ Environment Profile Releases and Routing Rules](#environment-profile-releases-and-routing-rules).
- **Secrets & authentication** — GitHub OIDC → Vault JWT with per-environment role and policy isolation, plus tooling to back up, migrate, and verify the Vault KV layout.
- **Backup, migration & DR** — cross-datacenter full-site migration and recovery, streamed through S3 object storage.
- **Supporting infrastructure** — self-hosted GitHub/Gitea action runners and observability agents (Vector / Node / Process exporters).

> ℹ️ **Architecture Upgrade Notice**: This toolkit has been refactored from a legacy "All-in-One" monolithic architecture into a highly cohesive architecture bounded by **Business Domains**. This allows us to decouple, migrate on-demand, and independently evolve different business systems. Simultaneously, we have fully implemented a unified [Multi-Environment Delivery Standard](docs/standards/multi-environment-delivery-and-release-standard.md).

## 🌐 Core Business Domains

This toolkit is divided into four core domains based on the actual business topology of the production systems:

1. **[web-saas](docs/domains/web-saas/README.md)** (SaaS Frontend & Acceleration Domain)
   - Covers Web Console, Accounts, Billing, and the underlying Xray tunnel proxy ingress.
2. **[ai-workspace](docs/domains/ai-workspace/README.md)** (AI Core Routing Domain)
   - Covers LiteLLM, OpenClaw, QMD, and other intelligent agent/model routing pipelines.
3. **[agent-proxy](docs/domains/agent-proxy/README.md)** (Acceleration Proxy & Gateway Domain)
   - Covers Caddy, Xray tunnels, Xray Exporters, Vector observability proxies, and agent-svc-plus control plane sync nodes.
4. **[open-platform](docs/domains/open-platform/README.md)** (Open Platform & Infrastructure Domain)
   - Covers Gitea, Vault, IAM (Zitadel), and a robust global Observability Stack (Grafana, VictoriaMetrics, etc.).

For detailed migration, backup, and restoration strategies for each domain, please refer to the `README.md` documents within their respective sub-directories.


## 🛠️ CI/CD and IaC Pipelines

When triggering deployments or migrations for the whole site or specific domains via CI/CD pipelines, the underlying logic will invoke the corresponding business domain strategy modules.

### Environment Profile Releases and Routing Rules

When triggered, `platform-ops.yaml` automatically routes to the appropriate delivery environment based on the current Git branch or tag. Terraform creates or updates the hosts first, then generates the CMDB; subsequently, Ansible will strictly use the CMDB inventory generated during that specific run.

| Trigger Event / Source | Target Environment | Resource Declaration | State Key / Workspace |
| --- | --- | --- | --- |
| `pull_request` | `sit` | `sit/all-in-one` | `platform-ops-toolkit/sit/all-in-one.tfstate` |
| `main` / `release/*` push | `uat` | `uat/web-saas` | `platform-ops-toolkit/uat/web-saas.tfstate` |
| `vMAJOR.MINOR.PATCH` tag | `prod` | `prod/web-saas` | `platform-ops-toolkit/prod/web-saas.tfstate` |
| `workflow_dispatch` | User selected | `[env]/[target_domains]` | `platform-ops-toolkit/[env]/[target_domains].tfstate` |

Prior to the initial UAT / Prod release, you must configure DNS for the target environment (the UAT web-saas host resolves as `console-uat.onwalk.net`) and populate the web-saas credentials in Vault. The workflow fails fast if they are missing: a dedicated validation step runs *before* any deployment action and exits non-zero on an empty value.

#### Recent UAT release records

The cross-repository Xray billing and observability delivery is tracked in the [UAT r2 change log](docs/tasks/2026-08-02-uat-r2-xray-billing-observability-change-log.md). It records the `uat-daily-build-2026.08.02-r2` snapshot, the merged PRs across Exporter, Billing, Accounts, Portal, GitOps, Playbooks and Platform Ops, plus the remaining UAT acceptance checks.

> ⚠️ **`pull_request` and merge-triggered pushes are plan-only.** Both `pull_request` and the `main` / `release/*` push routes now set `terraform_action=plan` and `toolkit_action=none`, so they validate IaC without creating or mutating real infrastructure. Use `workflow_dispatch` when you want an actual apply/deploy run.

#### `cloud_provider` (workflow_dispatch only, required)

Options: `aws-cloud` / `gcp-cloud` / `azure-cloud` / `vultr-vps`. No default — you must pick one.

**Only `vultr-vps` is wired end to end for these four business domains today**: the `config/resources/{sit,uat,prod}/*.yaml` host declarations, the base credentials (`VULTR_API_KEY`), and `VPS_ROOT`/`ENV_DIR` all target Vultr. Selecting anything else fails in a dedicated validation step immediately after checkout — before Vault, before Terraform — naming the value you chose and stating that only `vultr-vps` is implemented here.

The other three options exist because this is a multi-cloud-shaped toolkit, not a Vultr-only one: `iac_modules/terraform-hcl-standard/{aws-cloud,gcp-cloud,azure-cloud}` are real Terraform modules already exercised by the landing-zone / account-matrix / resources-matrix pipelines (see the multi-cloud bullet above). Extending `platform-ops.yaml` to a second provider means adding that provider's resource declarations and base credentials for each business domain — the validation step is what stands in for that work until it lands, so choosing an unimplemented provider fails loudly instead of silently deploying to Vultr under the wrong label.

### ⚠️ Vault Authentication Configuration (GitHub Actions OIDC → Vault JWT)

Pipelines do NOT store sensitive values in GitHub Actions Secrets. All credentials are distributed at runtime from Vault KV paths (`sit`, `uat`, `prod`) after authenticating via **GitHub OIDC → Vault JWT**.

#### 1. Initialize Isolated Roles and Policies (One-time Setup)

We have deprecated the global monolithic Vault Policy in favor of independent authorization per environment. You only need to execute the built-in initialization script using a Vault Administrator Token:

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # Admin Token

# Grant execution permissions and run
chmod +x docs/tasks/vault_auth_split.sh
./docs/tasks/vault_auth_split.sh
```

This script will automatically create:
- Three environment-specific policies: `github-actions-platform-ops-toolkit-sit`, `-uat`, `-prod`
- Three OIDC JWT authentication roles: `github-actions-platform-ops-toolkit-sit`, `-uat`, `-prod`
- Security constraints: the `prod` role accepts only `v*` tag triggers; every role additionally pins `job_workflow_ref` to an allowlist of this repo's Vault-using workflow files, so adding a new workflow cannot mint a token.

Verify the result — the layout invariants are executable assertions, not conventions:

```bash
./scripts/vault/vault_layout_verify.py   # exit 0 = all pass, usable as a CI gate
```

#### 2. Populate KV Parameters for Each Domain

The KV tree is split into three tiers by whether a secret has an *environment dimension* at all. See [Vault KV Tier Model](docs/vault/kv_tier_model.md) for the classification test and invariants.

| Tier | Vault Path | Example Keys | Access |
| --- | --- | --- | --- |
| ① Common services | `kv/data/CICD` | `GHCR_USERNAME`, `GHCR_TOKEN` | All three roles, **read-only** |
| ② Base credentials | `kv/data/CICD/<env>` | `SSH_PRIVATE_DEPLOY_KEY_B64`, `VULTR_API_KEY`, `TF_STATE_*` | **Own environment only**, read-only |
| ③ Environment secrets | `kv/data/<env>/*` | `databases`, `agent-proxy`, … | Own environment only, read/write (**prod denied `delete`**) |

Tiers ① and ② are read-only for every role: pipelines *consume* credentials, they do not *rotate* them. `prod` is denied `delete` on `kv/metadata` as well as `kv/data`, since a metadata delete destroys every version of a secret.

> **Migration status:** base credentials still live at the `kv/data/CICD` root; `kv/data/CICD/<env>` is authorized but not yet populated. Run `./scripts/vault/vault_migrate_base_credentials.sh --dry-run` to preview step one. Note that copying one credential set into three paths isolates the *paths* — the security benefit only lands once each environment holds genuinely distinct keys.

> **Known gap:** `kv/data/WEB_SAAS` is read by both `uat` and `prod`, so those two environments currently share one set of database passwords. It belongs in tier ③ and should become `kv/data/<env>/web-saas`. See [KV layout and migration](docs/vault/kv_layout_and_migration.md).

#### 3. Workflow Dynamic Authentication Integration (Active, No Changes Required)

During execution, the workflow derives the environment from the trigger event and requests the matching role, so each run can only reach its own environment's secrets:

```yaml
env:
  # The routing ternary is repeated per variable because the env context
  # cannot reference itself inside a workflow-level env: block.
  DEPLOY_ENV:    ${{ github.event_name == 'pull_request' && 'sit' || … }}
  VAULT_ROLE:    github-actions-platform-ops-toolkit-${{ … }}
  VAULT_KV:      kv/data/CICD                  # ① common services
  VAULT_KV_BASE: kv/data/CICD/${{ … }}         # ② base credentials, per environment
```

#### 4. Acceptance and Troubleshooting

- After triggering a pipeline, the `Authenticate to Vault` or `Load Vault secrets` step within each job should display successful Token retrieval info without errors.
- `403 Forbidden` error: This indicates that the policy bound to the dynamically assembled role does not cover the requested path (e.g., attempting to read production secrets from within the UAT environment).
- `permission denied` or Role mismatch error: Please verify whether the Git event triggering the pipeline (such as the branch name or Tag) satisfies the strict security boundary constraints defined in the `bound_claims` of the Vault JWT Role.
