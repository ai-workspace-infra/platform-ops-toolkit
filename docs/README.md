# Site Migration Toolkit: 基于 AI 驱动的站点级自动化迁移容灾解决方案

**Site Migration Toolkit** 是一套面向跨云 / 跨主机场景的自动化搬站与容灾工具包，覆盖环境 provision、服务部署与站点数据迁移。

在跨云、跨主机迁移这类高风险重载场景下，它以 **S3 对象存储作为流式传输中转**，避免在源端本地打包落盘；凭证经 **HashiCorp Vault OIDC JWT** 在运行时动态获取，不使用持久化的 GitHub Actions Secrets。支持的数据类型包括 Gitea 源码库、PostgreSQL 业务库、Docker 镜像集，以及 AI 应用的持久化工作区数据。

## 文档目录约定

`docs/` 按“领域边界、规范、方案、任务、验证材料”分层。新增文档应优先放入对应目录，避免把部署步骤、长期规范和一次性排障记录混在一起。

```text
docs/
├── README.md                         # 文档入口与导航
├── domains/                          # 业务域边界、组件清单、镜像/tag 约定
├── standards/                        # 跨环境交付、分支、发布等强制规范
├── plans/                            # 架构方案、迁移方案和长期设计
├── tasks/                            # 按日期记录的实施任务、排障与 E2E 用例
├── cases/                            # 可重复执行的运行手册和操作案例
├── vault/                            # Vault KV、OIDC、策略和迁移说明
├── assets/                           # 文档截图、流程图和指标图
├── EN/                               # 英文文档
├── ZH/                               # 中文专题/历史文档
├── daily-snapshot-manual.md          # Daily Snapshot 手动操作入口
└── resize-instance.md                # 实例规格调整操作入口
```

当前 UAT 探针与生产端点验证入口：[2026-08-01 UAT E2E 用例](tasks/2026-08-01-uat-probes-production-endpoints.md)。该文档可由其他 Codex Agent 按 TC-01～TC-09 独立执行，并将命令输出、运行链接和结论回填到执行记录中。

核心入口：

- [业务域交付清单](domains/DELIVERY-MANIFEST.md)
- [业务域目录说明](domains/README.md)
- [多环境交付与发布规范](standards/multi-environment-delivery-and-release-standard.md)
- [Daily Snapshot 手册](daily-snapshot-manual.md)
- [实例规格调整](resize-instance.md)
- [Stripe 套餐目录初始化 TL;DR](howto/stripe-billing-catalog-tldr.md)
- [UAT r2：Xray → Exporter → Billing → PostgreSQL → Accounts → Portal 变更记录](tasks/2026-08-02-uat-r2-xray-billing-observability-change-log.md)
- [UAT r5：Xray → Exporter → Vector → Billing 闭环重跑](tasks/2026-08-02-uat-xray-billing-fanout-r5-rerun.md)
- [UAT 两条 Xray 链路分段审计与验收清单](tasks/2026-08-02-uat-xray-billing-observability-chain-audit.md)
- [UAT r6 链路收口与释放门槛](tasks/2026-08-02-uat-r6-chain-closeout.md)

## 🌟 核心理念与特性 (Core Features)

- 🤖 **AI 辅助的配置生成**：借助大模型生成迁移策略、渲染复杂配置文件（如跨域 Caddy Domain 级联重写）。
- 🌊 **流式中转，避免源端打包落盘**：基于 Linux Pipes 与 S3，导出即上传、目标端边下边解，规避 `tar` 本地打包把源服务器磁盘写满的问题。传输过程本身不额外占用源端磁盘（容器与数据库自身的临时空间仍需预留）。
- 🛡️ **凭证经 Vault 动态下发**：不使用持久化的 GitHub Actions Secrets 或静态 `.env` 密钥文件。运行时经 OIDC JWT 换取短期 token 读取 S3 AK/SK，token 为不可续期的 `batch` 类型并随 TTL 过期。
  > 注意：这指的是**凭证来源**不落盘。部分部署环节仍会把渲染后的 `app.env` 等配置写入目标主机，那是服务运行所必需的，不在此范围内。
- ⚡ **增量同步与断点续传**：基于 `aws s3 sync` 的增量比对，大文件或弱网环境下中断后可续传，减少重传成本。
- 📦 **Docker 镜像离线投递**：针对镜像拉取限流（如 DockerHub Rate Limit）或目标端无外网的情况，支持源端 `docker save` 后经 S3 投递，目标端直接 `docker load`。

## 🔐 Vault OIDC 鉴权与策略隔离 (Vault Authentication & Policies)

为了在 CI/CD 部署时确保各个环境的凭证安全隔离，我们设计了三套平行的 Vault 策略 (Policies) 与 OIDC JWT 角色 (Roles)。您可通过执行 `docs/tasks/vault_auth_split.sh` 脚本在 Vault 中一键初始化该体系：

| 环境 (Env) | Vault 策略 / JWT 角色 | 绑定的 Git Ref (`bound_claims.ref`) |
| :--- | :--- | :--- |
| **SIT** | `github-actions-platform-ops-toolkit-sit` | `refs/pull/*/merge`、`refs/heads/*`（PR 验证与分支 dispatch） |
| **UAT** | `github-actions-platform-ops-toolkit-uat` | `refs/heads/main`、`refs/heads/release/*`（不含 `refs/heads/release/v*` 的 PROD 运行） |
| **PROD** | `github-actions-platform-ops-toolkit-prod` | **仅 `refs/tags/v*` 或 `refs/heads/release/v*`** |

三个角色另有三项通用约束：`user_claim` 用 `sub`（绑定到工作负载而非触发者用户名）、
`job_workflow_ref` 钉死到本仓库使用 Vault 的 workflow 白名单、`token_no_default_policy`
配合 `batch` token。

> **`job_workflow_ref` 白名单是这里最关键的一道约束**：仅靠 `ref` 拦不住「在仓库里新增
> 一个 workflow 文件来换取 token」，钉死文件名才能拦住。新增使用这些角色的 workflow 时，
> 必须同步更新 `vault_auth_split.sh` 里的白名单，否则换不到 token。

> ⚠️ **PROD 只接受 `refs/tags/v*` 或 `refs/heads/release/v*`**。
> `main`、其他 `release/*` 分支、daily/UAT/SIT/prod 快照 tag 以及其他来源均禁止进入
> PROD；`workflow_dispatch` 的环境输入不能覆盖这一 ref allowlist。

KV 路径按三层隔离（公共服务共读只读 / 基础凭据按环境只读 / 环境业务密钥按环境读写），
详见 [Vault KV 三层模型](vault/kv_tier_model.md) 与
[鉴权与策略隔离](vault/vault_authentication_and_policy_isolation.md)。

*脚本执行路径：* `bash docs/tasks/vault_auth_split.sh` (需具备 Vault Admin Token 并在同终端中执行)

## 🛠️ 技术栈与生态圈 (Technology Stack)

- **核心编排引擎**: Ansible / Ansible Vault
- **安全与身份网关**: HashiCorp Vault (动态 JWT / KV2)
- **底层对象存储隧道**: AWS S3 (或兼容的 MinIO / OSS / OBS)
- **CLI/自动化底座**: AWS CLI v2 / Shell Pipelines (`gzip` / `gunzip` stream)
- **首批支持开箱即用的技术栈**:
  - PostgreSQL (通过 `pg_dump` 管道)
  - Gitea Server (含静态归档向 S3 原生引擎的无缝切库)
  - Docker Containers (容器热备份)
  - Caddy / APISIX (网关配置自适应渲染)
  - QMD / OpenClaw (自定义数据目录热同步)

## 📖 目录导航

更详尽的灾备计划、系统概览及实施流程，请参考以下目录：

- [系统级实时概览 (Systems Overview)](ZH/Systems-Overview/PROD/live_systems_overview.md)
- [备份与容灾预案 (Backup & DR Plan)](ZH/BackUP/backup_dr_plan.md)
- [PostgreSQL 容灾实战 (PostgreSQL DR)](ZH/BackUP/postgresql_disaster_recovery.md)
- [Vault OIDC 策略与 403 排障 (Vault OIDC DR & Troubleshooting)](ZH/BackUP/vault_oidc_policy_troubleshooting.md)
- [迁移实施方案历史文档 (Site Migration Implementation)](ZH/BackUP/Site-Migration/implementation_plan.md)
- [Daily Snapshot 手动执行版](daily-snapshot-manual.md)
