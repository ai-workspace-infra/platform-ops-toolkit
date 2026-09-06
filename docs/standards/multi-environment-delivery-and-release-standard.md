# 多云多环境交付与发布规范
(Multi-Environment Delivery and Release Standard)

This page defines the infrastructure-wide working standard for multi-environment delivery, branch usage, release tagging, and secret governance within the `platform-ops-toolkit`.

## 1. Environment Profile Releases and Routing Rules

When triggered, `selfhost-orchestrator.yml` automatically routes selfhost infrastructure to the appropriate delivery environment based on the current Git branch or tag. Terraform creates or updates the hosts first, then generates the CMDB; subsequently, Ansible will strictly use the CMDB inventory generated during that specific run.

| Trigger Event / Source | Target Environment | Resource Declaration | State Key / Workspace |
|---|---|---|---|
| `pull_request` | `sit` | `sit/all-in-one.yaml` | `sit/vultr-vps/platform-ops-toolkit/all-in-one.tfstate` |
| `refs/heads/main` or `refs/heads/release/*` except `refs/heads/release/v*` | `uat` | `uat/web-saas-uat.yaml` | `uat/vultr-vps/platform-ops-toolkit/web-saas.tfstate` |
| `refs/heads/release/v*` push | `prod` | `prod/web-saas-prod.yaml` | `prod/vultr-vps/platform-ops-toolkit/web-saas.tfstate` |
| `refs/tags/v*` push | `prod` | `prod/web-saas-prod.yaml` | `prod/vultr-vps/platform-ops-toolkit/web-saas.tfstate` |
| `workflow_dispatch` | User selected; Daily Main Snapshot may author a `v*` release from `main` only when its source is a verified immutable tag | `[env]/web-saas-[env].yaml` | Environment specific |

State keys MUST follow `<env>/<cloud>/<project>/<resource-set>.tfstate`.
The Terraform workspace uses the same dimensions as `<env>-<cloud>-<project>-<resource-set>`.
Apply and destroy MUST resolve both values through the same routing script.

### 1.1 Ref and environment combinations

The cross-repository tag operation uses one tagging script for both stable
release tags and daily build tags. The tag prefix is the only release-class
selector; an existing tag is never moved or overwritten.

| Combination | Meaning | Policy |
|---|---|---|
| `main + uat` | Normal continuous delivery | Default branch delivery path; safe default for routine changes |
| `release/v* + prod` | Controlled production operation | The only production branch route; must be explicitly approved and protected |
| `main + sit` | Low-frequency validation | Manual verification only; not a scheduled delivery path |
| `v*` tag | Controlled stable production release | Manually selected release tag only; immutable, never moved/overwritten/deleted, and never used as an automatic build tag |
| `daily-build-*` tag | Daily automatic build snapshot | Scheduled daily build artifact path for UAT/build verification |
| `uat-daily-build-*` tag | Allowed UAT build/retry snapshot | Explicitly allowed UAT variant for retries, validation, and environment handoff |
| `sit-*` tag | SIT snapshot | Low-frequency test snapshot; used only when SIT validation is explicitly requested |

The shared tagging script must receive the intended tag explicitly. Stable
release publication and daily snapshot publication differ by the tag value and
the selected environment, not by a second tag-creation implementation. A
Daily Main Snapshot has one deliberately narrow production path: a manual run
from protected `main` may take a verified immutable `v*`, `daily-build-*`, or
`uat-daily-build-*` `snapshot_source_ref` and create a new immutable `v*`
release tag. `main` is only the control-plane ref for that action; it is never
the production artifact source. This path uses the dedicated
`github-actions-platform-ops-toolkit-prod-release` Vault role, pinned to this
workflow and `refs/heads/main`; it does not widen the general production role.

Production deployment is fail-closed to exactly two artifact refs:
`refs/tags/v*` and `refs/heads/release/v*`. Apart from the dedicated release
authoring path above, `main`, other `release/*` branches, and all daily
snapshot tags are not production sources. The selected verified source tag and
the resulting release tag must be recorded in deployment evidence.

### 1.2 PROD public DNS cutover boundary

Production deployment and customer-facing DNS cutover are separate approvals. The deployment
pipeline may publish and verify the mode-qualified Cloudflare/Web SaaS services, but must not
automatically switch the following canonical aliases. An operator performs this CNAME change only
after readiness and security checks pass. The serverless target names are the canonical
`*-serverless-prod.*` names; the retired `*-cloudflare-prod.*` variant must not be used:

| Public entry | CNAME target |
|---|---|
| `xworktech.com` | `console-serverless-prod.xworktech.com` |
| `www.svc.plus` | `console-serverless-prod.svc.plus` |
| `console.svc.plus` | `console-serverless-prod.svc.plus` |
| `accounts.svc.plus` | `accounts-serverless-prod.svc.plus` |
| `billing.svc.plus` | `billing-serverless-prod.svc.plus` |

`assets.svc.plus` and `install.svc.plus` are not part of this cutover. The apex
`xworktech.com` record requires CNAME flattening or an equivalent apex-alias capability at the DNS
provider. Any workflow input or script that uses a `*-cloudflare-prod.*` name is invalid; use the
declared `*-serverless-prod.*` or `*-selfhost-prod.*` endpoint instead.

`console-serverless-prod.svc.plus`, `console-serverless-prod.xworktech.com`, and
`www.xworktech.com` are bound to the `frontend-router-prod` Worker. The Pages project is only the static asset origin and must not
claim these UI hostnames. The declared production `static_cdn_url` (`assets.svc.plus`) is the
Pages custom domain and is reconciled separately with its Pages CNAME.

GitOps `spec.serverless.console_aliases` declares `www.xworktech.com` for production
serverless and hybrid topology. The Serverless domains job reconciles it even with
`dns_mode=none`. Its homepage must serve in place without redirecting to
`console.xworktech.com`. Public-chain verification rejects HTTP redirects on all
declared frontend aliases. A Cloudflare 403 challenge retains the protected-edge
acceptance path; it does not prove application content readiness.

### 1.3 PROD source allowlist (mandatory)

The only artifact refs that may target `prod` are:

- `refs/tags/v*`
- `refs/heads/release/v*`

The following are explicitly forbidden as PROD sources, even when a workflow
input or tag prefix appears to request `prod`:

- `refs/heads/main`, feature/bugfix/hotfix branches, and any other branch;
- `refs/heads/release/*` except `refs/heads/release/v*`;
- `refs/tags/daily-build-*`, `refs/tags/uat-daily-build-*`, `refs/tags/sit-*`,
  `refs/tags/snapshot-*`, and `refs/tags/prod-*`;
- pull-request refs and a `workflow_dispatch` run from any non-allowlisted ref,
  except the dedicated Daily Main Snapshot release-authoring workflow on `main`.

The dedicated Daily Main Snapshot release-authoring workflow on protected
`main` is the sole exception for verified `daily-build-*` and
`uat-daily-build-*` source tags; it promotes either source to a new immutable
`v*` release tag and does not deploy the daily tag directly.

An environment input, deploy tag, Vault role name, or helper-script inference
must not widen this allowlist. A ref that is not allowlisted must fail closed
before production credentials or production deployment steps are used.

### State 演进与迁移治理

状态 key 是资源生命周期的唯一索引，不得在普通 deploy 中自动尝试旧 key。平台切换层级、项目名、云厂商或资源集合时，必须走一次显式迁移：

1. 冻结旧 key 的 apply/destroy，并记录旧 key、旧 workspace、资源清单和云厂商实例 ID。
2. 备份并校验旧 state，确认所有实例均属于目标环境和资源集合。
3. 在受控迁移任务中复制 state 到新 key，或使用 Terraform state migration/adopt 流程更新资源地址。
4. 使用新 key/workspace 执行 `terraform plan`，必须是预期的 `0 to add`、`0 to destroy`。
5. 完成一次 apply、destroy 演练和 CMDB 对账后，才允许恢复常规部署。
6. 旧 key 保留审计记录，但常规流水线不得回退读取。

这样可以支持后续从单项目、单云扩展到多项目、多云，而不把旧 state 漂移隐藏在“自动兼容”逻辑中。

> [!IMPORTANT]
> Prior to the initial UAT / Prod release, you must configure DNS for the target environment (e.g., `console.uat.svc.plus` or the production domains) and inject the corresponding `kv/data/[env]/web-saas` credentials into Vault. The workflow will fail if these credentials are missing. Environments are strictly isolated, and pipelines will never read secrets across environments.

## 2. Vault Authentication Configuration (OIDC → Vault JWT)

Pipelines do **NOT** store sensitive values in GitHub Actions Secrets. All credentials are distributed at runtime from Vault KV paths (`sit`, `uat`, `prod`) after authenticating via GitHub OIDC → Vault JWT.

### Initialize Isolated Roles and Policies (One-time Setup)

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
- **Security constraints**: The general `prod` role is strictly bound to only accept `refs/tags/v*` or `refs/heads/release/v*`. A separate role permits only Daily Main Snapshot on protected `main` to author a release tag from a verified immutable source.

## 3. Branch Roles and Delivery Lifecycle

We adhere strictly to the following branch roles, inherited from the application-level development standard:

| Ref | Role | Typical Lifetime | Lands Into |
|---|---|---|---|
| `main` | Main timeline / trunk (Triggers `uat` env) | Long-lived | Receives `feature/*`, `bugfix/*`, `cherry-pick/*` |
| `release/*` | LTS maintenance line (Triggers `uat`, except `release/v*`) | Long-lived, version-scoped | Receives `hotfix/*` and intentional `backport/*` |
| `feature/*` | New feature work (Triggers `sit` via PR) | Short-lived | `main` |
| `bugfix/*` | Normal bug fix work for trunk | Short-lived | `main` |
| `hotfix/*` | Urgent fix for a published release line | Short-lived | `release/*` |
| `tag` (`v*`) | Published release snapshot (Triggers `prod` env) | Immutable | Marks a release point |

### Allowed Paths and Pull Requests
- All changes must be made via Pull Requests. Direct pushes to `main` and `release/*` are prohibited by branch protection rules; `release/v*` also requires the production release approval path.
- `feature/*`, `bugfix/*` PRs must target `main` and be squash-merged.
- `hotfix/*` PRs must target `release/*`.

### Release Cut and Publishing
1. A `release/vMAJOR.MINOR` branch is cut from a stable `main` commit.
2. Production is deployed **only** from an approved `refs/heads/release/v*`
   branch push or an immutable `refs/tags/v*` tag. Daily Main Snapshot authors
   that tag from protected `main` by re-tagging an already verified immutable
   source; it never deploys the `main` commit as production.
3. Every production artifact and infrastructure state must be traceable to the
   exact source ref and immutable artifact digest recorded in deployment
   evidence.

## 4. Emergency Secret Incident Flow

If an infrastructure secret, token, or private key is accidentally committed:
1. **Revoke** the leaked credential immediately in Vault or the cloud provider.
2. **Generate** or rotate a replacement credential.
3. Review access logs and audit trails for suspicious use.
4. Rewrite Git history only after the credential is no longer valid.
5. Force-push the rewritten branches and tags.
6. Have collaborators `git fetch --all` and re-align local branches as needed.

> [!CAUTION]
> A secret-scanning gate prevents new leakage but does not replace this incident flow. Never attempt to just "delete the file" in a new commit to hide a leak; Git history must be purged.
