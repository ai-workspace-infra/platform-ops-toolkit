# Daily Snapshot 手动执行版

> 2026-09-30 规划更新：Daily 目标职责为只读检查 Vault → Observability → IAM 就绪后发布业务，不再触发 Shared 平台部署/升级。当前代码仍有差距，本文旧操作步骤不能作为新规则已经生效的证据；先阅读 [Shared / UAT / PROD 多云环境与发布链路规划](plans/shared-uat-prod-multicloud-environment-delivery.md)。

`Daily Main Snapshot` 仅使用 GitHub App 认证。workflow 通过 GitHub OIDC 登录 Vault，读取 App 私钥并按目标组织生成 installation token。

Daily 负责 SIT/UAT 快照构建、Shared 只读就绪检查，以及按参数选择 SIT/UAT/PROD 的发布矩阵。
PROD 只接受已经验证的受保护 `v*` tag，并由 Selfhost Orchestrator 执行资源部署；Daily
不创建 release tag、执行数据迁移或切换生产 DNS。详见[多环境交付与发布规范](standards/multi-environment-delivery-and-release-standard.md)。

## 前置配置

Vault KV v2 路径：

```text
kv/data/CICD/github-app/daily-snapshot
```

字段：

```text
app_private_key
```

SIT/UAT 使用与矩阵环境对应的 Vault role；生产发布使用独立的受保护 role。Daily
不会读取生产发布凭据，也不会创建生产 release tag。

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
5. 选择 `deploy_env`（`sit`、`uat` 或 `prod`）。矩阵只执行所选环境的映射，不把 UAT 写死为
   默认派发目标；PROD 必须使用已验证的受保护 `v*` tag，可选填写 `snapshot_tag` / `snapshot_source_ref`。

workflow 会从各仓库当时的 `main` SHA 创建不可变的
`daily-build-YYYY.MM.DD` tag，并继续执行目标仓库的构建触发流程。
构建等待会同时按 tag 名和 SHA 匹配，避免误用同名历史运行。

汇总 Job 会把本次运行的环境（`sit`、`uat` 或 `prod`）写入每条矩阵记录，
并上传 `daily-snapshot-summary-<environment>` artifact。环境总览或其他只读同步器
应读取该 artifact 的 `daily-snapshot-summary.json`，按 `environment`、组织和仓库
展示状态；不要把 UAT 和 PROD 的同名 tag 或构建结果合并成一条资源记录。

资源总览还必须遵守 [UAT / PROD resource aggregation contract](resource-aggregation-model.md)：
GitOps 只代表 desired state，provider API、DNS、健康检查和部署 CMDB 才能证明
observed state。只有声明而没有观察记录的资源必须显示为 `declared_only`。

## 环境矩阵自动联动

当未使用 `repositories` 缩小范围时，快照矩阵全部构建成功后会自动：

1. 从各组织状态 artifact 解析唯一的不可变快照 tag；
2. 只读检查 Shared 就绪：Vault → Observability → IAM（`check-shared-readiness.sh`）。任一失败即停止，不发布业务；Shared 的部署、升级、迁移属于独立的 `open-platform-orchestrator.yml`，Daily 不触碰；
3. 根据 `deploy_env` 选择 GitOps 拓扑文件和对应 orchestrator：SIT 使用 Serverless，UAT 使用 Hybrid，PROD 使用 Selfhost；派发参数、目标域名和 Vault 环境均来自矩阵/GitOps，不由脚本硬编码；等待子流程完成并在汇总 Job 中写入环境回执。PROD 使用 `dns_mode=none`，不执行主库或 DNS 切换。

Daily 不接受迁移、基线采纳或 release tag 创建参数。需要数据库导入、schema migration、baseline
或生产数据切换时，直接使用 `environment-data-operations.yml` 及其 Playbooks role，并按
GitOps 拓扑校验目标环境和执行路径；Daily 的 PROD 路径只部署已验证 `v*` 制品，不触碰数据。

部分仓库筛选或 SIT 快照不会自动触发 UAT；这避免不完整制品集进入 UAT。

UAT 的后续 Agent Proxy 部署由 `selfhost-orchestrator.yml` 路由到 Akamai Cloud
JP/US/SG，并把 Ulighthost existing TW 作为独立 non-IaC leg。PROD 则拆成两条
selfhost leg：现有 AWS 节点使用 `aws-cloud` 且不包含 existing 节点，Akamai Cloud
JP/US/SG 使用 `akamai-cloud` 并包含 Ulighthost existing PH/TW。PROD 旧 AWS 节点继续
纳入矩阵，但 AWS SPOT 不再是 Daily Snapshot 的默认新建资源。

稳定发布 tag 与日常构建 tag 共用同一个跨仓库打标脚本，区别只在 tag
值和路由语义：`daily-build-*` 是每日自动构建，`uat-daily-build-*` 是允许的
UAT 构建/重试 tag，`sit-*` 是低频 SIT 验证。`v*` / `release/v*` 的生产 tag 由
受保护的 Playbooks + GitOps 流程负责；Daily 只消费已存在且已验证的 `v*` tag 派发 Selfhost，
不创建或晋级这些 tag。

路由组合约定：

- `main + uat`：常规交付默认路径。
- `main + sit`：低频手动验证，基本不参与日常调度。
- `main + prod`：仅允许已验证的 `v*` tag，派发 Selfhost Orchestrator，保持 `dns_mode=none`。
- `daily-build-*`：每日自动构建入口。
- `uat-daily-build-*`：允许的 UAT 构建、重试与验证入口。
- `release/*`（不含 `release/v*`）：UAT 路径，不得进入 PROD。
- `vYYYY.MM.DD[-rN]`：PROD 稳定发布 tag，由受保护的正式发布流程创建；Daily 仅校验并消费该 tag，
  已存在且指向别处时拒绝，不移动、覆盖或删除。

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
