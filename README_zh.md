# platform-ops-toolkit

[🇬🇧 English](README.md) · [🇨🇳 中文版](README_zh.md) · [English alternate](README_EN.md)

## 先看这里：真正的操作入口

如果你是第一次使用，只需要按下面 4 步走：

1. 准备一个可以被 GitHub Actions Runner 访问的 Vault Server，当前默认地址是 [`https://vault.svc.plus`](https://vault.svc.plus)。
2. 用 Vault 管理员 Token 执行 [`scripts/create_vault_service_repo_roles.sh`](scripts/create_vault_service_repo_roles.sh)，配置 GitHub Actions OIDC → Vault JWT。
3. 打开本仓库的 **Actions → Deploy Environment & Provision Infrastructure → Run workflow**。
4. 按目标环境填写参数，点击 **Run workflow**。真正的部署、扩容、迁移、备份和恢复都从这里进入。

入口 workflow 文件是：

```text
.github/workflows/selfhost-orchestrator.yml
```

本仓库是**入口仓库**，不是所有配置的存放地。日常应该修改的是下面三个核心仓库：

| 仓库 | 职责 | 什么时候修改 |
| --- | --- | --- |
| [`platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | GitHub Actions 入口、流程编排、参数和通用运维脚本 | 想启动任务，或修改流水线行为 |
| [`playbooks`](https://github.com/ai-workspace-infra/playbooks) | Ansible Playbook、OS 初始化和可复用的业务域 CD workflow | 想修改主机配置、应用安装或部署逻辑 |
| [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) | Terraform 模块、云资源、主机和环境资源声明 | 想创建或调整云资源、VPS、网络或 Terraform |
| [`gitops`](https://github.com/ai-workspace-infra/gitops) | 环境运行配置和 GitOps desired state | 想修改域名、服务参数、镜像 tag 或环境配置 |
| [`artifacts`](https://github.com/ai-workspace-infra/artifacts) | 可选的镜像、压缩包、构建产物和发布清单 | 只有发布流程需要复用或追溯产物时才使用 |

记忆方法：`platform-ops-toolkit` 负责“按按钮”，`iac_modules` 负责“建资源”，`playbooks` 负责“装和配应用”，`gitops` 负责“声明环境最终状态”。

## 第一次使用：完整向导

### 1. 准备 Vault Server

GitHub Actions 不直接保存云密钥、SSH 私钥和业务密钥。Vault 必须已经初始化、已解封，并且 Runner 可以访问。

当前默认地址是：[`https://vault.svc.plus`](https://vault.svc.plus)

如果使用其他地址，在手动运行 workflow 时填写 `vault_addr` 覆盖默认值。

### 2. 配置 GitHub Actions OIDC → Vault JWT

这是一次性初始化步骤，需要 Vault 管理员权限：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # Vault 管理员 Token

chmod +x scripts/create_vault_service_repo_roles.sh
./scripts/create_vault_service_repo_roles.sh
```

详细的 JWT auth、Role/Policy、workflow claim、KV 隔离和故障排查，请阅读 [Vault 鉴权与策略隔离手册](docs/vault/vault_authentication_and_policy_isolation.md)。本 README 只负责新人向导和操作入口。

初始化后校验：

```bash
./scripts/vault/vault_layout_verify.py
```

退出码为 `0` 才算通过。不要把 `VAULT_TOKEN` 提交到仓库，也不要填入 workflow input。

#### 2.1 脚本创建的 Role 与权限

脚本创建 3 个环境 policy 和 6 个 JWT role。两组 role 使用同一套环境 policy，但 workflow 白名单不同：

| Role | Policy | 允许的 workflow | Ref 边界 |
| --- | --- | --- | --- |
| `github-actions-platform-ops-toolkit-sit` | `...-sit` | toolkit workflow allowlist | PR merge ref、任意分支 |
| `github-actions-platform-ops-toolkit-uat` | `...-uat` | toolkit workflow allowlist | `main`、`release/*`、`bugfix/*`、`daily-build-*` |
| `github-actions-platform-ops-toolkit-prod` | `...-prod` | toolkit workflow allowlist | `main`、`v*` tag |
| `github-actions-playbooks-sit` | `...-sit` | playbooks domain-CD allowlist | PR merge ref、任意分支 |
| `github-actions-playbooks-uat` | `...-uat` | playbooks domain-CD allowlist | `main`、`release/*`、`bugfix/*`、`daily-build-*` |
| `github-actions-playbooks-prod` | `...-prod` | playbooks domain-CD allowlist | `main`、`v*` tag |

所有 role 都绑定 `repository`、`job_workflow_ref` 和 Git ref。新加 workflow 不会自动获得 Vault 权限。

KV 权限摘要：

| KV 路径 | `sit` / `uat` | `prod` |
| --- | --- | --- |
| `kv/data/CICD`、`kv/data/openclaw`、`kv/data/action-runner` | `read` | `read` |
| `kv/data/CICD/domains/*` | `create/read/update/list` | `create/read/update/list` |
| `kv/data/CICD/<env>` | 只读本环境 | 只读本环境 |
| `kv/data/<env>/*` | `create/read/update/delete/list` | `create/read/update/list`，禁止 delete |
| `kv/metadata/<env>/*` | `list/read/delete` | `list/read`，禁止 delete |

当前脚本的 `prod` role 允许 `main` 和 `v*` tag；如果要改成仅 tag 发布，必须修改脚本本身。

### 3. 填充 Vault KV

流水线登录 Vault 后主要读取三类路径：

| 类型 | 路径 | 示例 |
| --- | --- | --- |
| 公共 CI 凭据 | `kv/data/CICD` | GHCR、公共运行时凭据 |
| 环境基础凭据 | `kv/data/CICD/<env>` | `VULTR_API_KEY`、Terraform State、SSH 私钥 |
| 环境业务密钥 | `kv/data/<env>/*` | 数据库、Billing、agent-proxy 等密钥 |

`<env>` 为 `sit`、`uat` 或 `prod`。生产环境的密钥不要交给普通 workflow 负责删除或轮换。

### 4. 从 Actions 页面运行

打开：**Actions → Deploy Environment & Provision Infrastructure → Run workflow**。

第一次运行建议：

| 参数 | 建议 |
| --- | --- |
| `runner_type` | `ubuntu-latest` |
| `deploy_tag` | 已存在的不可变镜像版本，例如 `daily-build-2026.07.30-r1` |
| `infra_ref` / `playbooks_ref` / `gitops_ref` | 三个核心仓库使用匹配的 `main` 或 release ref |
| `target_domains` | 先选一个业务域，不要第一次直接选 `all` |
| `cloud_provider` | 当前业务域链路只有 `vultr-vps` 端到端可用 |
| `vault_env_path` | 与目标环境一致：`sit`、`uat` 或 `prod` |
| `run_infrastructure` | 要创建或更新主机时勾选 |
| `run_application_deploy` | 要部署应用时勾选；必须同时勾选 infrastructure |
| `run_full_stack` | 从零创建环境时使用，会联动基础设施、应用和 DNS |

建议先只做基础设施并检查 CMDB，再做应用部署。测试时不要勾选 `confirm_dns_switch`。

## 其他工作流入口

| Workflow | 用途 | 入口和注意事项 |
| --- | --- | --- |
| [`data-migration.yaml`](.github/workflows/data-migration.yaml) | 数据迁移、备份、恢复 | 可被主 workflow 调用，也可手动运行；第一次保持 `accounts_dry_run=true` |
| [`daily-main-snapshot.yaml`](.github/workflows/daily-main-snapshot.yaml) | 跨组织、跨仓库生成 `daily-build-*` 快照 tag，并触发构建 | 定时或手动运行；结果 tag 可作为 `deploy_tag` |
| [`k6-performance-test.yaml`](.github/workflows/k6-performance-test.yaml) | k6 压测并上报可观测性指标 | 手动运行；先用 `smoke`，再提高 VU 数 |
| [`cron-rotate-domain-tls-certs.yaml`](.github/workflows/cron-rotate-domain-tls-certs.yaml) | 更新域名 TLS 证书并写入 Vault | 每两个月或手动运行，需要 Cloudflare 凭据 |

### daily-main-snapshot 的 GitHub App 特殊权限

该 workflow 的 `permissions:` 只控制默认 `GITHUB_TOKEN`，不提供跨组织权限。它会从 Vault 读取 App 私钥，按组织创建 installation token，再用 `GH_TOKEN` 列仓库、创建 tag、触发构建、查看 workflow run 和 release assets。

必须满足：

- 在 matrix 中的每个组织安装同一个 GitHub App：`ai-workspace-infra`、`ai-workspace-lab`、`ai-workspace-services`、`ai-workspace-xstream`。
- App installation 必须能访问目标仓库；尽量使用 selected repositories 收敛范围。
- 至少授予 `Contents: Read and write` 和 `Actions: Read and write`。
- App 私钥存放在 `kv/data/CICD/github-app/daily-snapshot` 的 `app_private_key`。
- `owner: matrix.organization` 必须与 App installation 的组织一致。

官方参考：[GitHub App in Actions](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow)、[选择 GitHub App 权限](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)、[`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)。

## 触发方式与执行关系

| 触发方式 | 默认环境 | 说明 |
| --- | --- | --- |
| Pull Request | `sit` | 校验和计划，不是生产发布入口 |
| push 到 `main` / `release/*` | `uat` | 校验和计划 |
| `v*` tag | `prod` | 生产发布路径 |
| `workflow_dispatch` | 手动选择 | 真正执行 provision、deploy、migration、backup、restore 等动作 |

一次主部署的顺序是：

```text
platform-ops-toolkit
  → OIDC 登录 Vault
  → iac_modules / Terraform 创建资源并生成 CMDB
  → playbooks / Ansible 使用本次 CMDB 部署应用
  → gitops 提供或更新环境目标配置
```

## 切换到个人项目

当前 workflow 是为 `ai-workspace-infra` 编排的，`web-saas`、`ai-workspace`、`agent-proxy`、`infra-platform` 都是当前项目的业务域，不是通用模块。

切换个人项目时至少修改：

1. `.github/workflows/selfhost-orchestrator.yml` 中的 `ai-workspace-infra/iac_modules`、`playbooks`、`gitops` 和所有 reusable workflow `uses:`。
2. `playbooks` 和 GitOps 内部引用的 service repository、镜像 registry、域名和 tag。
3. `target_domains`、Terraform host/resource matrix、job 条件和 Vault 路径，删除个人项目不存在的业务域。
4. GitHub App 的安装组织、selected repositories、Contents/Actions 权限，以及自动更新 GitOps 所需的写权限。
5. [`vault_auth_split.sh`](scripts/create_vault_service_repo_roles.sh) 的 `REPO`、`PLAYBOOKS_REPO`、workflow allowlist 和新的 policy/role。

可用下面的搜索检查旧项目绑定：

```bash
rg -n 'ai-workspace-infra|ai-workspace-xstream|compassvpn|svc\.plus|onwalk\.net' \
  .github docs config scripts
```

## 常见问题

### 我应该改哪个仓库？

云资源改 `iac_modules`，主机和应用部署改 `playbooks`，环境目标状态改 `gitops`；只有入口参数和编排逻辑改本仓库。

### Actions 里没有 Run workflow？

确认你有 Actions 权限，并且当前分支的 workflow 包含 `workflow_dispatch`。

### Vault 返回 403？

检查 Vault 地址、JWT auth、role 的 repository/ref/workflow claim、KV 路径和 `vault_env_path` 是否一致。然后运行 `vault_layout_verify.py`。

### 为什么 AWS/GCP/Azure 失败？

这些是预留的多云选项；当前业务域交付链路只有 `vultr-vps` 端到端接通。

## 详细文档

- [Vault 鉴权与策略隔离](docs/vault/vault_authentication_and_policy_isolation.md)
- [Vault KV 三层模型](docs/vault/kv_tier_model.md)
- [多环境交付标准](docs/standards/multi-environment-delivery-and-release-standard.md)
- [业务域文档](docs/domains/README.md)
- [Selfhost 入口 workflow](.github/workflows/selfhost-orchestrator.yml)
