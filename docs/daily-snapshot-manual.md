# Daily Snapshot 手动执行版

> 2026-09-30 规划更新：Daily 目标职责为只读检查 Vault → Observability → IAM 就绪后发布业务，不再触发 Shared 平台部署/升级。当前代码仍有差距，本文旧操作步骤不能作为新规则已经生效的证据；先阅读 [Shared / UAT / PROD 多云环境与发布链路规划](plans/shared-uat-prod-multicloud-environment-delivery.md)。

`Daily Main Snapshot` 仅使用 GitHub App 认证。workflow 通过 GitHub OIDC 登录 Vault，读取 App 私钥并按目标组织生成 installation token。

Daily 负责 SIT/UAT 快照构建、Shared 只读就绪检查和 UAT Hybrid 发布；在 UAT
验收清单通过后，也支持受保护的 UAT→PROD 晋级。PROD 晋级必须填写已成功的
`uat_daily_run_id`，只晋级该 UAT run 验收的镜像 digest，并在 `production` Environment
审批后创建不可变 `v*` tag、发布 Serverless 与 selfhost。它不从源码重建，也不自动做
canonical DNS cutover。通用 PROD workflow 仍只能由受保护的 `v*` tag 或 `release/v*`
分支触发；Daily 使用专用 `prod-release` Vault role。详见[多环境交付与发布规范](standards/multi-environment-delivery-and-release-standard.md)。

## 前置配置

Vault KV v2 路径：

```text
kv/data/CICD/github-app/daily-snapshot
```

字段：

```text
app_private_key
```

UAT 使用 Vault role `github-actions-platform-ops-toolkit-uat`；PROD 晋级使用独立的
`github-actions-platform-ops-toolkit-prod-release` role。后者只能被受保护的
`daily-main-snapshot.yaml` 主线发布入口使用，并且只在 production Environment 审批后
读取该 App 私钥。

GitHub App `daily-snapshot-tag`（App ID `4405545`）需要安装到四个目标组织，并拥有目标仓库的：

- `Contents: Read and write`
- `Actions: Read and write`
- `Workflows: Read and write`（快照 tag 会触发目标仓库 CI）

快照在写入第一个 tag 前会使用 installation token 预检全部目标仓库。
如果预检返回 403，应检查目标组织中该 App 对仓库的实际安装范围；不要通过手工
删除或移动已有 tag 来重试，因为快照 tag 是不可变的。PROD 的 `v*` tag 不由 Daily
创建。

## 执行步骤

1. 打开 `platform-ops-toolkit` 的 `Actions`。
2. 选择 `Daily Main Snapshot`。
3. 点击 `Run workflow`。
4. 确认 workflow ref 使用受保护的 `main`。
5. 选择 `deploy_env`。常规发布使用 `uat`；PROD 选择 `prod` 后必须填写已验收的
   `uat_daily_run_id`。可选填写 `snapshot_tag` / `snapshot_source_ref`，但它们必须与
   该 UAT run 验收出的 release tag / snapshot tag 一致。
6. 仅在完整 UAT Hybrid 成功后需要自动进入 PROD 审批时，选择 UAT 的
   `promote_prod_after_uat`；部分仓库筛选不能进入 PROD。

workflow 会从各仓库当时的 `main` SHA 创建不可变的
`daily-build-YYYY.MM.DD` tag，并继续执行目标仓库的构建触发流程。
构建等待会同时按 tag 名和 SHA 匹配，避免误用同名历史运行。

汇总 Job 会把本次运行的环境（`sit` 或 `uat`）写入每条矩阵记录，
并上传 `daily-snapshot-summary-<environment>` artifact。环境总览或其他只读同步器
应读取该 artifact 的 `daily-snapshot-summary.json`，按 `environment`、组织和仓库
展示状态；不要把 UAT 和 PROD 的同名 tag 或构建结果合并成一条资源记录。

资源总览还必须遵守 [UAT / PROD resource aggregation contract](resource-aggregation-model.md)：
GitOps 只代表 desired state，provider API、DNS、健康检查和部署 CMDB 才能证明
observed state。只有声明而没有观察记录的资源必须显示为 `declared_only`。

## UAT 自动联动

当 `deploy_env=uat` 且未使用 `repositories` 缩小范围时，快照矩阵全部构建成功后会自动：

1. 从各组织状态 artifact 解析唯一的不可变快照 tag；
2. 只读检查 Shared 就绪：Vault → Observability → IAM（`check-shared-readiness.sh`）。任一失败即停止，不发布业务；Shared 的部署、升级、迁移属于独立的 `open-platform-orchestrator.yml`，Daily 不触碰；
3. dispatch `hybrid-orchestrator.yml`（`operation=deploy`、`target_domains=all`、`vault_env_path=uat` 和该 tag）并等待其完成。Serverless / Selfhost 子流水线由 Hybrid 按 GitOps UAT 矩阵逐行派发。

Hybrid 没有对应输入，因此 **`enable_migration`、`apply_accounts_schema_migration`、`adopt_accounts_baseline`、`xconnect_one_release_tag`、`xconnect_gateway_release_tag` 在 UAT 下会在派发前直接失败**，而不是被静默忽略后仍显示成功。需要这些操作时，直接执行 `serverless-orchestrator.yml`（例如 `deploy+migrate`）或对应的 XConnect 工作流。Hybrid 固定以 `skip_stripe_catalog=true` 派发子流水线，Daily 的该开关对 UAT Hybrid 不生效。

部分仓库筛选或 SIT 快照不会自动触发 UAT；这避免不完整制品集进入 UAT。

UAT 的后续 Agent Proxy 部署由 `selfhost-orchestrator.yml` 路由到 Akamai Cloud
JP/US/SG，并把 Ulighthost existing TW 作为独立 non-IaC leg。PROD 则拆成两条
selfhost leg：现有 AWS 节点使用 `aws-cloud` 且不包含 existing 节点，Akamai Cloud
JP/US/SG 使用 `akamai-cloud` 并包含 Ulighthost existing PH/TW。PROD 旧 AWS 节点继续
纳入矩阵，但 AWS SPOT 不再是 Daily Snapshot 的默认新建资源。

稳定发布 tag 与日常构建 tag 共用同一个跨仓库打标脚本，区别只在 tag
值和路由语义：`daily-build-*` 是每日自动构建，`uat-daily-build-*` 是允许的
UAT 构建/重试 tag，`v*` 是 UAT 验收后由受保护晋级步骤创建的正式 PROD 发布，
`sit-*` 是低频 SIT 验证。PROD 运行不能直接把 daily tag 部署到生产；它先验证
UAT manifest，再为同一组源 SHA 创建不可变 `v*` tag。

路由组合约定：

- `main + uat`：常规交付默认路径。
- `main + sit`：低频手动验证，基本不参与日常调度。
- `daily-build-*`：每日自动构建入口。
- `uat-daily-build-*`：允许的 UAT 构建、重试与验证入口。
- `release/*`（不含 `release/v*`）：UAT 路径，不得进入 PROD。
- `vYYYY.MM.DD[-rN]`：PROD 稳定发布 tag，由受保护的正式发布流程或 Daily 的
  `prod-release` 晋级步骤创建；已存在且指向别处时拒绝，不移动、覆盖或删除。

`main` 只能作为 workflow 的控制面入口，不能作为 PROD 制品来源；PROD 制品是 UAT
验收清单中的镜像 digest。不要手工预建 `v*` tag。

手工创建重试快照 tag 时可执行：

```bash
bash docs/tasks/tag-ai-workspace-mains.sh \
  --tag daily-build-2026.07.29-r1 \
  --apply \
  --ref main \
  --build
```

### 强行清理历史快照残留

如果因为特殊原因手动删除了快照 Tag，但没有清理关联的 GitHub Release，在重新触发工作流时会导致构建报错（如 `manifest_missing`）。此时可用清理脚本强行清理目标快照的所有残留记录：

```bash
# 清理四大组织内所有相关仓库的某个 Tag 及关联 Release
bash docs/tasks/clean-snapshot-tag-and-release.sh --tag daily-build-2026.07.29

# 或者仅针对构建报错的特定仓库清理
bash docs/tasks/clean-snapshot-tag-and-release.sh \
  --tag daily-build-2026.07.29 \
  --repo ai-workspace-services/accounts,ai-workspace-services/billing-service
```

所有 tag 均保持不可变。当天基础 tag 已存在、对应构建失败或 `main` 已前进时，
使用 `-r1`、`-r2` 等新 tag 重试。环境看板和后续部署应从这些不可变快照中
选择“构建成功且创建时间最新”的 tag，而不是移动旧 tag。

不需要配置 `GH_TOKEN`、`CROSS_REPO_GH_TOKEN` 或 GitHub PAT。

## Vault role 要求

创建 tag 的 workflow 使用 `github-actions-platform-ops-toolkit-uat`，但各服务的
构建 workflow 不能复用普通 `sit` / `uat` role。构建发生在
`refs/tags/daily-build-*` 上，因此每个服务需要一个独立 role，例如：

```text
github-actions-accounts-uat
github-actions-billing-service-uat
github-actions-content-service-uat
github-actions-console-uat
github-actions-postgresql-uat
```

这些 role 由统一入口 `docs/tasks/vault_auth_split.sh` 创建，至少需要绑定：

```text
ref = refs/tags/daily-build-*
repository = <service repository>
job_workflow_ref = <service repository>/.github/workflows/ci-pipeline.yml@refs/tags/daily-build-*
```

role 只读构建所需的 Vault 路径，并只允许 `sit` / `uat` 的 GHCR 或制品发布路径。
不要把 `daily-build-*`、`uat-daily-build-*`、`sit-*`、`snapshot-*` 或
`prod-*` 加入生产 role；生产 role 只能接受
`refs/tags/v*` 和 `refs/heads/release/v*`。

如果服务 workflow 仍使用 `workflow_dispatch` 而不是 tag push，还必须让它显式使用
`daily-build-*` 作为 checkout ref、镜像 tag、binary/zip 名称和 chart version。
