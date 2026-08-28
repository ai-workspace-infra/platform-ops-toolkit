# Vault Authentication and Policy Isolation

本文档详细记录了 `platform-ops-toolkit` 在基于 GitHub OIDC JWT 登录 Vault 时的多环境（`sit`、`uat`、`prod`）隔离策略。

## 架构原则

平台采用严格的“按环境隔离”鉴权策略。这意味着无论是在 Vault Policy 还是在 GitHub OIDC JWT Role 层面，每一个环境的权限都互不交叉。

流水线在执行过程中，绝不会使用持久化的 GitHub Actions Secrets 存储敏感值。所有运行时的部署凭证均经由 **GitHub OIDC → Vault JWT** 登录后，从对应环境的 Vault KV 路径中动态拉取。

---

## 1. 环境与角色（Role）映射策略

为确保高敏环境（尤其是 `prod` 环境）的安全，Vault 中定义了三个独立的 JWT Role。每个 Role 通过 Vault 的 `bound_claims` 特性，严格锁定了只有当触发 GitHub Actions 的 Git `ref`（分支或标签）符合特定正则或通配符要求时，才允许换取环境凭证。

| 目标环境 (Env) | Vault JWT Role 名称 | 允许请求的 Git 分支 / Tag (`bound_claims` / `ref`) | 用途说明 |
| --- | --- | --- | --- |
| **`sit`** | `github-actions-platform-ops-toolkit-sit` | **`refs/pull/*/merge`**、**`refs/heads/*`** | Pull Request 验证，以及从分支发起的 `workflow_dispatch`。ref 仍然较宽，真正的收敛来自 `job_workflow_ref` 白名单。 |
| **`uat`** | `github-actions-platform-ops-toolkit-uat` | **`refs/heads/main`**、**`refs/heads/release/*`**（生产例外见下行） | `main` 与非 `release/v*` 的 `release/*` push 路由到 UAT。 |
| **`prod`** | `github-actions-platform-ops-toolkit-prod` | **仅 `refs/tags/v*` 或 `refs/heads/release/v*`** | 受控正式 tag 或受保护的版本发布分支。 |
| **`prod` release authoring** | `github-actions-platform-ops-toolkit-prod-release` | **仅 `refs/heads/main` + `daily-main-snapshot.yaml`** | 只能把已验证的 immutable `v*` 或 `uat-daily-build-*` source tag 重新标记为全新 `v*` release tag。 |

通用 PROD role 的 ref allowlist 是严格且封闭的：`refs/tags/v*` 与
`refs/heads/release/v*` 之外的任何 ref 都必须拒绝。`main` 只可通过专用
release-authoring role 运行 Daily Main Snapshot，且不能作为制品来源；非
`release/v*` 分支、`daily-build-*`、`uat-daily-build-*`、`sit-*`、`snapshot-*`、
`prod-*` 和其他 tag/branch 不得通过通用生产 role。

> **注**：在 `platform-ops.yaml` 流水线中，环境变量会通过逻辑计算自动映射：  
> `VAULT_ROLE: github-actions-platform-ops-toolkit-${{ env.DEPLOY_ENV }}`

### 1.1 三项通用硬化（2026-07-22）

所有 role 统一采用：

| 配置 | 值 | 原因 |
| --- | --- | --- |
| `user_claim` | `sub` | 身份绑定到工作负载（repo+ref+workflow），而非触发者的 GitHub 用户名（`actor`）。 |
| `job_workflow_ref` | 本仓库 6 个 workflow 文件的白名单（`@*` 收尾放行任意 ref，包含受保护的 `resize-instance.yaml`） | **仓库里新增一个 workflow 换不到任何 role**。这是 ref 之外最关键的一道约束。 |
| `token_no_default_policy` | `true` | 不附加 `default` policy，最小权限。 |
| `token_type` / `token_ttl` | `batch` / `20m` | 一次部署用不了 1 小时；batch token 不可续期。 |

> ⚠️ **行为约束**：通用 `prod` 只能由 `refs/tags/v*` 或
> `refs/heads/release/v*` 触发。专用 `prod-release` role 是唯一例外，且仅授予
> `daily-main-snapshot.yaml@refs/heads/main` 以创建新 release tag；workflow 输入、
> tag 名称或脚本推断都不能再放宽这个范围。
>
> 已删除的死角色：`github-actions-platform-ops-toolkit-prod-tags` 从未被任何 workflow 请求过，职责已并入 `-prod`。

---

## 2. Vault Policy 数据路径隔离

除了 Role 的触发源隔离外，每个 Role 背后所绑定的 Vault Policy 也对其实际能够读写的 KV 数据范围做了强隔离。

路径分**三层**：公共服务共读只读、基础凭据按环境拆分且只读自己那份、环境专属业务密钥可读写。

| 层 | KV Path | sit | uat | prod | 权限 |
| --- | --- | --- | --- | --- | --- |
| **① 公共服务** | `kv/data/CICD`（GHCR 拉取凭据）<br>`kv/data/openclaw`<br>`kv/data/action-runner` | ✅ | ✅ | ✅ | **只读，不可修改** |
| **② 基础凭据** | `kv/data/CICD/<env>`（`VULTR_API_KEY` / `TF_STATE_*` / `SSH_PRIVATE_DEPLOY_KEY_B64`） | 仅 `sit` | 仅 `uat` | 仅 `prod` | **只读** |
| **③ 环境业务密钥** | `kv/data/<env>/*` | 仅 `sit` | 仅 `uat` | 仅 `prod` | 可读写（prod 无 `delete`） |
| 业务（待拆） | `kv/data/WEB_SAAS` | ❌ | ✅ | ✅ | 只读 |

### 2.1 为什么这样分层

**① 公共服务共享**——GHCR 拉的是同一批镜像，不存在「环境」这个维度，拆成三份只会产生三份需要同步轮换的副本，不产生隔离收益。这一层**只给 `read`，任何 role 都不能写**：公共资产不允许被任何单一环境的流水线改动。

**② 基础凭据必须按环境拆**——`VULTR_API_KEY`、`TF_STATE_*`、`SSH_PRIVATE_DEPLOY_KEY_B64` 授予的是「控制基础设施」和「登录主机」的能力，是提权的实际载体。sit 失陷不应该拿到 prod 的云账号和主机私钥。这一层同样**只给 `read`**——流水线消费凭据，不负责轮换凭据。

> **KV v2 路径语义**：`kv/data/CICD` 与 `kv/data/CICD/<env>` 是两个**独立的 secret**（一个路径既可以是 secret 本身，也可以是子路径的前缀）。而 policy 里 `path "kv/data/CICD"` **只精确匹配根路径、不匹配子路径**（匹配子路径需要写 `kv/data/CICD/*`）。因此「共读根路径 + 只读自己那份子路径」可以严格成立，各环境读不到彼此的基础凭据。

绑定收紧与路径隔离是**两道独立的防线**：绑定（`job_workflow_ref` 白名单 + 各自 `ref`）决定「谁能换到 token」，路径决定「换到之后能看到什么」。

> ⚠️ **未决问题**：`kv/data/WEB_SAAS` 由 uat 与 prod 共读，内含 `POSTGRES_ROOT_PASSWORD`、`ACCOUNT_DB_PASSWORD`——即两个环境共用同一套数据库口令。数据库口令属于第 ③ 层（环境专属业务密钥），不是公共服务凭据，后续应拆分为 `kv/data/<env>/web-saas`。

> 📋 `kv/` 根下现存路径的**逐条归位与迁移计划**见
> [kv_layout_and_migration.md](./kv_layout_and_migration.md)——包含 `prod/` 缺失、
> 4 个 workflow 仍从根路径读基础凭据、7 个 service 路径未授权等已梳理出的问题。

### 2.2 迁移顺序（重要）

基础凭据从根路径搬到 `kv/data/CICD/<env>` 需要按序执行，否则流水线会读到空值：

1. **先写数据**：为每个环境在 `kv/CICD/{sit,uat,prod}` 写入各自的 `VULTR_API_KEY` / `TF_STATE_*` / `SSH_PRIVATE_DEPLOY_KEY_B64`。
2. 应用本 policy（跑 `vault_auth_split.sh`）。
3. 合并 workflow 侧的 `VAULT_KV_BASE` 改动。
4. **最后**从根路径 `kv/CICD` 删掉已搬走的基础凭据，只留 GHCR 等公共服务键。

> 第 1 步可以先直接复制现有的同一份凭据到三个路径下让链路先跑通，但**真正的隔离收益要等到三个环境换成各自独立的凭据**（独立 Vultr API key、独立 SSH 密钥对）才成立。在那之前，路径已隔离但凭据仍复用。

> ⚠️ **其他安全约束**：
> 1. `sit` Role 绑定的 Policy 绝对不能包含 `kv/data/uat/*` 或 `kv/data/prod/*` 的读写权限。
> 2. `prod` 环境的 Policy **已剥夺 `delete` 权限**，只允许 `create`/`read`/`update`。注意 `kv/metadata/*` 的 `delete` 会**永久销毁一个 secret 的所有版本**，因此 prod 的 metadata 也只给 `list`/`read`。

---

## 3. 自动化初始化与部署实践

所有环境对应的 Role 和 Policy 都不需要手动通过 Vault UI 点击配置。我们提供了一个自动化、幂等的初始化 Bash 脚本。

当您第一次部署 `platform-ops-toolkit` 或需要全量覆盖刷新策略时，只需使用 Vault Admin Token 运行以下初始化脚本：

```bash
# 位于 platform-ops-toolkit 项目根目录中
chmod +x docs/tasks/vault_auth_split.sh
./docs/tasks/vault_auth_split.sh
```

该脚本执行完毕后，上述的三套隔离的 Policy、Role 以及绑定规则将立即在 Vault 侧生效，支撑流水线后续安全运转。
