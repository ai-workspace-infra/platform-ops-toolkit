# platform-ops-toolkit

[🇬🇧 English](README.md) | [🇨🇳 中文版](README_zh.md)

欢迎使用 **platform-ops-toolkit**。本仓库是 AI Workspace 基础设施的平台运维控制面，覆盖的是完整生命周期，而不只是备份：

- **Provisioning** —— 基于 Terraform 的主机 provisioning，以及面向 landing-zone baseline、account/VPC matrix、resources matrix 的多云 IaC 流水线。
- **部署** —— 四个业务域各自的按服务 Ansible 部署，每次 run 都基于当次新生成的 CMDB。
- **多云是设计目标，但目前接线并不均衡** —— `iac_modules` 已经为 `aws-cloud` / `gcp-cloud` / `azure-cloud` / `vultr-vps` 准备了真实的 Terraform 模块，landing-zone / account-matrix / resources-matrix 这几条流水线四个都在用。下面提到的四个业务域流水线（`platform-ops.yaml`）**目前只接了 Vultr**：`cloud_provider` 在这里是必选参数，确保目标云永远显式选择，但选择 `vultr-vps` 之外的任何值都会直接失败，而不是悄悄部署到 Vultr 却挂着别的云的名字。详见下方 [环境 Profile 发布与路由规则](#环境-profile-发布与路由规则)。
- **密钥与鉴权** —— GitHub OIDC → Vault JWT，按环境隔离 role 与 policy，并配有校验、迁移、备份 Vault KV 布局的工具。
- **备份、迁移与容灾** —— 跨机房整体迁移与恢复，经 S3 对象存储流式传输。
- **配套基础设施** —— 自托管的 GitHub/Gitea Action Runner，以及可观测性代理（Vector / Node / Process exporters）。

> ℹ️ **架构升级提示**：本工具集已从旧版 "All-in-One" 单体架构，重构为以 **业务域 (Business Domain)** 为边界的高内聚架构。这使我们能够对不同业务系统解耦、按需迁移、独立演进。同时我们已全面落地统一的 [多环境交付标准](docs/standards/multi-environment-delivery-and-release-standard.md)。

## 🌐 核心业务域

本工具集依据线上系统的实际业务拓扑，划分为四个核心域：

1. **[web-saas](docs/domains/web-saas/README.md)**（SaaS 前端与加速域）
   - 涵盖 Web Console、Accounts、Billing，以及底层的 Xray 隧道代理入口。
2. **[ai-workspace](docs/domains/ai-workspace/README.md)**（AI 核心路由域）
   - 涵盖 LiteLLM、OpenClaw、QMD 等智能代理/模型路由链路。
3. **[agent-proxy](docs/domains/agent-proxy/README.md)**（加速代理与网关域）
   - 涵盖 Caddy、Xray 隧道、Xray Exporter、Vector 可观测性代理，以及 agent-svc-plus 控制面同步节点。
4. **[open-platform](docs/domains/open-platform/README.md)**（开放平台与基础设施域）
   - 涵盖 Gitea、Vault、IAM（Zitadel），以及完整的全局可观测性底座（Grafana、VictoriaMetrics 等）。

各域详细的迁移、备份、恢复策略，请查阅各子域目录内的 `README.md`。


## 🛠️ CI/CD 与 IaC 流水线

通过 CI/CD 流水线触发全站或指定域的部署/迁移时，底层逻辑会调用对应的业务域策略模块。

### 环境 Profile 发布与路由规则

触发时，`platform-ops.yaml` 会根据当前 Git 分支或 tag 自动路由到对应的交付环境。Terraform 先创建或更新主机，再生成 CMDB；随后 Ansible 严格只使用该次 run 生成的 CMDB inventory。

| 触发事件 / 来源 | 目标环境 | 资源声明 | State Key / Workspace |
| --- | --- | --- | --- |
| `pull_request` | `sit` | `sit/all-in-one` | `platform-ops-toolkit/sit/all-in-one.tfstate` |
| `main` / `release/*` push | `uat` | `uat/web-saas` | `platform-ops-toolkit/uat/web-saas.tfstate` |
| `vMAJOR.MINOR.PATCH` tag | `prod` | `prod/web-saas` | `platform-ops-toolkit/prod/web-saas.tfstate` |
| `workflow_dispatch` | 用户选择 | `[env]/[target_domains]` | `platform-ops-toolkit/[env]/[target_domains].tfstate` |

首次 UAT / Prod 发布前，需要为目标环境配置好 DNS（UAT 的 web-saas 主机解析为 `console-uat.onwalk.net`），并在 Vault 里填好 web-saas 凭证。缺失时 workflow 会快速失败：有专门的校验步骤在任何部署动作**之前**执行，取到空值就非零退出。

> ⚠️ **`pull_request` 会 provision 并部署真实基础设施。** `sit` 路由设置的是 `terraform_action=apply`、`toolkit_action=deploy` —— 不是只做 plan 的干跑。评估 `sit` role 的 Vault policy 爆炸半径时要把这一点算进去。

#### `cloud_provider`（仅 workflow_dispatch，必选）

选项：`aws-cloud` / `gcp-cloud` / `azure-cloud` / `vultr-vps`。无默认值 —— 必须显式选择。

**目前这四个业务域只有 `vultr-vps` 是端到端接好线的**：`config/resources/{sit,uat,prod}/*.yaml` 的主机声明、基础凭据（`VULTR_API_KEY`）、`VPS_ROOT`/`ENV_DIR` 全部指向 Vultr。选别的值会在 checkout 之后、Vault 与 Terraform 之前的一步专门校验里直接失败，报错信息会点名你选了什么、并说明这里目前只实现了 `vultr-vps`。

另外三个选项之所以存在，是因为这本来就是一个按多云设计的工具集，不是 Vultr 专用工具：`iac_modules/terraform-hcl-standard/{aws-cloud,gcp-cloud,azure-cloud}` 是真实存在、已经被 landing-zone / account-matrix / resources-matrix 流水线使用的 Terraform 模块（见上文多云那条）。要把 `platform-ops.yaml` 接到第二个云，需要为每个业务域补上该云的资源声明与基础凭据 —— 在这些工作落地之前，那道校验步骤就是占位：选一个还没实现的 provider 会直接报错，而不是悄悄部署到 Vultr 却挂着别的名字。

### ⚠️ Vault 鉴权配置（GitHub Actions OIDC → Vault JWT）

流水线不会把敏感值存进 GitHub Actions Secrets。所有凭证都是运行时经 **GitHub OIDC → Vault JWT** 登录后，从 Vault KV 路径动态下发。

GitHub Actions OIDC → Vault JWT 的详细接入步骤，包括 JWT auth 配置、Role/Policy 绑定、workflow claim、KV 隔离和故障排查，请阅读 [Vault 鉴权与策略隔离手册](docs/vault/vault_authentication_and_policy_isolation.md)。本 README 只保留新人向导和操作入口。

#### 1. 初始化隔离的 Role 与 Policy（一次性操作）

已废弃全局大一统的 Vault Policy，改为按环境独立授权。只需用 Vault 管理员 Token 执行内置的初始化脚本：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # 管理员 Token

# 赋予执行权限并运行
chmod +x docs/tasks/vault_auth_split.sh
./docs/tasks/vault_auth_split.sh
```

该脚本会自动创建：
- 三套环境专属 policy：`github-actions-platform-ops-toolkit-sit`、`-uat`、`-prod`
- 三套 OIDC JWT 鉴权 role：`github-actions-platform-ops-toolkit-sit`、`-uat`、`-prod`
- 安全约束：`prod` role 当前接受 `main` 和 `v*` tag 触发；每个 role 还额外把 `job_workflow_ref` 钉死到本仓库使用 Vault 的 workflow 白名单，仓库里新增一个 workflow 换不到任何 role。

跑完之后校验结果 —— 分层不变式是可执行断言，不是约定：

```bash
./scripts/vault/vault_layout_verify.py   # exit 0 = 全部通过, 可做 CI 门禁
```

#### 1.1 脚本创建的 Role 与权限矩阵

`vault_auth_split.sh` 会创建 3 个环境 policy，以及 6 个 JWT role。两组 role 使用相同的环境 policy，但分别限制在 platform toolkit 自身的 workflow 和 Playbooks reusable workflow：

| Role | 绑定的 Policy | 允许的 workflow 来源 | 分支 / tag 边界 | Token 约束 |
| --- | --- | --- | --- | --- |
| `github-actions-platform-ops-toolkit-sit` | `github-actions-platform-ops-toolkit-sit` | platform toolkit allowlist | PR merge ref、任意分支 | batch token，TTL 1h，无 default policy |
| `github-actions-platform-ops-toolkit-uat` | `github-actions-platform-ops-toolkit-uat` | platform toolkit allowlist | `main`、`release/*`、`bugfix/*`、`daily-build-*` 分支和 tag | 同上 |
| `github-actions-platform-ops-toolkit-prod` | `github-actions-platform-ops-toolkit-prod` | platform toolkit allowlist | `main` 和 `v*` tag | 同上 |
| `github-actions-playbooks-sit` | `github-actions-platform-ops-toolkit-sit` | Playbooks domain-CD allowlist | PR merge ref、任意分支 | 同上 |
| `github-actions-playbooks-uat` | `github-actions-platform-ops-toolkit-uat` | Playbooks domain-CD allowlist | `main`、`release/*`、`bugfix/*`、`daily-build-*` 分支和 tag | 同上 |
| `github-actions-playbooks-prod` | `github-actions-platform-ops-toolkit-prod` | Playbooks domain-CD allowlist | `main` 和 `v*` tag | 同上 |

所有 role 都同时绑定调用仓库的 `repository`、允许的 `job_workflow_ref` 和 Git ref。也就是说，只有被 allowlist 列出的 workflow 才能换取 token；仅仅在仓库里新增一个 workflow，不会自动获得 Vault 权限。

每个环境 policy 的实际 KV 权限如下：

| KV 路径 | `sit` / `uat` | `prod` | 说明 |
| --- | --- | --- | --- |
| `kv/data/CICD`、`kv/data/openclaw`、`kv/data/action-runner` | `read` | `read` | 公共 CI 和运行时凭据，只读 |
| `kv/metadata/CICD`、`kv/metadata/action-runner` | `list`, `read` | `list`, `read` | 只能查看 metadata，不能删除公共 secret |
| `kv/data/CICD/github-app/daily-snapshot`、`kv/data/CICD/observability` | `read` | `read` | 快照和可观测性凭据 |
| `kv/data/CICD/domains/*` | `create`, `read`, `update`, `list` | `create`, `read`, `update`, `list` | 跨环境共享的域名证书；故意允许更新，但不允许删除 |
| `kv/metadata/CICD/domains/*` | `list`, `read` | `list`, `read` | 证书 metadata，不允许删除 |
| `kv/data/CICD/<env>` | `read` | `read` | 当前环境的云账号、Terraform State、SSH 私钥，只读 |
| `kv/metadata/CICD/<env>` | `list`, `read` | `list`, `read` | 当前环境基础凭据 metadata |
| `kv/data/WEB_SAAS` | `read`（当前 sit 不授权） | `read` | 当前兼容路径；uat/prod 仍共享，后续应迁移到 `kv/data/<env>/web-saas` |
| `kv/data/<env>/*` | `create`, `read`, `update`, `delete`, `list` | `create`, `read`, `update`, `list` | 环境专属业务密钥；prod 禁止 data delete |
| `kv/metadata/<env>/*` | `list`, `read`, `delete` | `list`, `read` | prod 禁止 metadata delete，避免永久删除所有版本 |

注意：`prod` role 当前按脚本允许 `main` 和 `v*` tag；如果生产必须只能由版本 tag 发布，需要同时收紧脚本中的 prod `ref`，不能只改 README。

#### 2. 为各域填充 KV 参数

KV 树按「这个 secret 到底有没有环境维度」分成三层。判据与不变式见 [Vault KV 三层模型](docs/vault/kv_tier_model.md)。

| 层 | Vault 路径 | 示例键 | 权限 |
| --- | --- | --- | --- |
| ① 公共服务 | `kv/data/CICD` | `GHCR_USERNAME`、`GHCR_TOKEN` | 三个 role 共读，**只读** |
| ② 基础凭据 | `kv/data/CICD/<env>` | `SSH_PRIVATE_DEPLOY_KEY_B64`、`VULTR_API_KEY`、`TF_STATE_*` | **仅本环境**，只读 |
| ③ 环境业务密钥 | `kv/data/<env>/*` | `databases`、`agent-proxy` 等 | 仅本环境，可读写（**prod 无 `delete`**） |

①②两层对所有 role 都只读：流水线**消费**凭据，不负责**轮换**凭据。`prod` 在 `kv/metadata` 上同样没有 `delete`——metadata 的 delete 会销毁一个 secret 的全部版本。

> **迁移状态**：基础凭据目前仍在 `kv/data/CICD` 根路径；`kv/data/CICD/<env>` 已授权但尚未写入数据。跑 `./scripts/vault/vault_migrate_base_credentials.sh --dry-run` 预览第一步。注意把同一份凭据复制进三个路径只是隔离了*路径*——真正的安全收益要等各环境持有各自独立的密钥才成立。

> **已知缺口**：`kv/data/WEB_SAAS` 目前由 `uat` 与 `prod` 共读，两个环境共用同一套数据库口令。它本该属于第 ③ 层，应拆分为 `kv/data/<env>/web-saas`。详见 [KV 布局与迁移计划](docs/vault/kv_layout_and_migration.md)。

#### 3. Workflow 动态鉴权接入（已生效，无需改动）

执行时，workflow 会根据触发事件推导出环境并请求对应的 role，因此每次 run 只能读到自己环境的密钥：

```yaml
env:
  # 路由三元表达式在每个变量上都重复了一遍, 因为 env 上下文在 workflow 顶层
  # 的 env: 块内不能引用自身。
  DEPLOY_ENV:    ${{ github.event_name == 'pull_request' && 'sit' || … }}
  VAULT_ROLE:    github-actions-platform-ops-toolkit-${{ … }}
  VAULT_KV:      kv/data/CICD                  # ① 公共服务
  VAULT_KV_BASE: kv/data/CICD/${{ … }}         # ② 基础凭据, 按环境
```

#### 4. 验收与排障

- 触发流水线后，每个 job 的 `Authenticate to Vault` 或 `Load Vault secrets` 步骤应显示成功获取 Token，且无报错。
- `403 Forbidden`：说明动态拼装出来的 role 所绑定的 policy 没有覆盖所请求的路径（例如在 uat 环境里读取 prod 的密钥）。
- `permission denied` 或 role 不匹配：请确认触发流水线的 Git 事件（分支名或 tag）是否满足该 Vault JWT role 的 `bound_claims` 安全边界。
