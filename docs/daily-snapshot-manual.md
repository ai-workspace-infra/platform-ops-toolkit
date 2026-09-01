# Daily Snapshot 手动执行版

`Daily Main Snapshot` 仅使用 GitHub App 认证。workflow 通过 GitHub OIDC 登录 Vault，读取 App 私钥并按目标组织生成 installation token。

本手册也支持受控的 PROD 发布：从 `main` 启动 workflow，选择一个已验证的
`snapshot_source_ref`，并为它创建一个新的不可变 `v*` release tag。生产来源由
`snapshot_source_ref` 决定，而不是触发 workflow 的分支；详见
[多环境交付与发布规范](standards/multi-environment-delivery-and-release-standard.md)。

## 前置配置

Vault KV v2 路径：

```text
kv/data/CICD/github-app/daily-snapshot
```

字段：

```text
app_private_key
```

Vault role `github-actions-platform-ops-toolkit-uat` 需要具备该路径的只读权限。

GitHub App `daily-snapshot-tag`（App ID `4405545`）需要安装到四个目标组织，并拥有目标仓库的：

- `Contents: Read and write`
- `Actions: Read and write`
- `Workflows: Read and write`（生产 `v*` tag 会触发目标仓库 CI）

生产快照在写入第一个 tag 前会使用 installation token 预检全部目标仓库。
如果预检通过但创建 `refs/tags/v*` 仍返回 403，应检查目标组织中该 App 对仓库的
实际安装范围，以及组织级 tag ruleset 是否允许 `daily-snapshot-tag` 绕过；不要通过
手工删除或移动已有 tag 来重试，因为快照 tag 是不可变的。

## 执行步骤

1. 打开 `platform-ops-toolkit` 的 `Actions`。
2. 选择 `Daily Main Snapshot`。
3. 点击 `Run workflow`。
4. 选择 `deploy_env`，默认使用 `uat`。
5. 可选填写 `snapshot_tag` 和 `repositories`。

workflow 会从各仓库当时的 `main` SHA 创建不可变的
`daily-build-YYYY.MM.DD` tag，并继续执行目标仓库的构建触发流程。
构建等待会同时按 tag 名和 SHA 匹配，避免误用同名历史运行。

## UAT 自动联动

当 `deploy_env=uat` 且未使用 `repositories` 缩小范围时，快照矩阵全部构建成功后会自动：

1. 从各组织状态 artifact 解析唯一的不可变快照 tag；
2. 使用 GitHub App installation token dispatch `serverless-orchestrator.yml`；
3. 固定传入 `operation=deploy+migrate`、`vault_env_path=uat` 和该 tag；
4. 等待 Serverless Orchestrator 完成 Cloud Run/Cloudflare 发布，再执行 Supabase Accounts 增量迁移与验证。

因此 Daily Main Snapshot 成功后不再需要手工复制 tag 到第二个 workflow。部分仓库筛选、SIT 或 PROD 快照不会自动触发 UAT；这避免不完整制品集进入 UAT。手工重跑仍可直接执行
`serverless-orchestrator.yml` 的 `deploy+migrate`。

稳定发布 tag 与日常构建 tag 共用同一个跨仓库打标脚本，区别只在 tag
值和路由语义：`daily-build-*` 是每日自动构建，`uat-daily-build-*` 是允许的
UAT 构建/重试 tag，`v*` 是受控手动选择的正式 PROD 发布，`sit-*` 是低频
SIT 验证。Daily Snapshot 不能把 `v*` 作为 `snapshot_tag`；否则服务 CI 和
平台路由会把日常构建误判为正式发布。

路由组合约定：

- `main + uat`：常规交付默认路径。
- `main + prod`：从经过验证的 `snapshot_source_ref` 创建新的受控稳定发布 tag。
- `main + sit`：低频手动验证，基本不参与日常调度。
- `daily-build-*`：每日自动构建入口。
- `uat-daily-build-*`：允许的 UAT 构建、重试与验证入口。
- `release/*`（不含 `release/v*`）：UAT 路径，不得进入 PROD。
- `vYYYY.M.D[-rN]` 或 `vX.Y.Z[-rN]`：Prod 使用的全新稳定发布 tag；同一天需要再次发布时递增 `-rN`（例如 `v2026.8.28-r1`、`v2026.8.28-r2`）。它由 workflow 在各目标仓库从已验证 source tag 创建，不得预先存在、移动、覆盖或删除。

`main` 只能作为 workflow 的控制面入口，不能作为 PROD 制品来源。PROD 的
`snapshot_source_ref` 仅允许已验证的 `v*` 或 `uat-daily-build-*` tag；
`daily-build-*`、`sit-*`、`snapshot-*`、`prod-*` 以及任何 branch 都不得作为
PROD 来源。

### 生产 release 的推荐发布顺序

生产 tag 应从**已经成功验证的不可变 `v*` 或 `uat-daily-build-*` tag**派生，
而不是直接从 `main` 切出。不要预先手动创建 release tag；Daily Main Snapshot 会在
目标仓库中将所选 source tag 重新标记为新的不可变 `v*` tag。

例如当天第二次发布可使用 `v2026.8.28-r2`，其 `snapshot_source_ref` 选择已成功
验证的 `uat-daily-build-2026.8.28-rN`（或历史 `v*` tag）。从 `main` 运行 Daily
Snapshot，Prod 预检会拒绝 `main` 作为 `snapshot_source_ref`，然后在每个目标仓库
将所选 source tag 重新标记为新的 release tag。`v*` 只允许 Prod，UAT 仍使用
`main` 默认值或 `uat-daily-build-*`。

### 生产 release 的推荐发布顺序

生产 tag 应从**已经成功验证的不可变 `v*` 或 `uat-daily-build-*` tag**派生，
而不是直接从 `main` 切出：

```bash
# verified_tag 必须是已成功完成 UAT/Prod 验证的历史 v* 或 uat-daily-build-* tag
# new_tag 不能已存在
git fetch origin --tags
git tag -a new_tag verified_tag -m "Production release new_tag"
git push origin new_tag
```

例如当天第二次发布可使用 `v2026.8.28-r2`，其父 tag 应是已验证的
`v2026.8.28-r1`，其 `snapshot_source_ref` 可以选择已成功验证的
`uat-daily-build-2026.8.28-rN`（或历史 `v*` tag）。运行 Daily Snapshot 时，
Prod 的 `snapshot_source_ref` 选择该已验证 tag，`snapshot_tag` 必须等于当前
workflow 使用的 release tag；选择 `main` 会在生产预检阶段被拒绝。`v*` 只允许
Prod，UAT 仍使用 `main` 默认值或 `uat-daily-build-*`。

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
