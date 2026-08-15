# Daily Snapshot 手动执行版

`Daily Main Snapshot` 仅使用 GitHub App 认证。workflow 通过 GitHub OIDC 登录 Vault，读取 App 私钥并按目标组织生成 installation token。

本手册只用于 SIT/UAT 快照构建。Daily Snapshot 不是 PROD 发布入口；即使
workflow 暴露了 `deploy_env=prod` 输入，也不得用日快照或 UAT 快照进入生产。
PROD 只接受 `refs/tags/v*` 或 `refs/heads/release/v*`，详见
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

## 执行步骤

1. 打开 `platform-ops-toolkit` 的 `Actions`。
2. 选择 `Daily Main Snapshot`。
3. 点击 `Run workflow`。
4. 选择 `deploy_env`，默认使用 `uat`。
5. 可选填写 `snapshot_tag` 和 `repositories`。

workflow 会从各仓库当时的 `main` SHA 创建不可变的
`daily-build-YYYY.MM.DD` tag，并继续执行目标仓库的构建触发流程。
构建等待会同时按 tag 名和 SHA 匹配，避免误用同名历史运行。

稳定发布 tag 与日常构建 tag 共用同一个跨仓库打标脚本，区别只在 tag
值和路由语义：`daily-build-*` 是每日自动构建，`uat-daily-build-*` 是允许的
UAT 构建/重试 tag，`v*` 是受控手动选择的正式 PROD 发布，`sit-*` 是低频
SIT 验证。Daily Snapshot 不能把 `v*` 作为 `snapshot_tag`；否则服务 CI 和
平台路由会把日常构建误判为正式发布。

路由组合约定：

- `main + uat`：常规交付默认路径。
- `refs/heads/release/v* + prod`：受控生产分支路径，必须经过生产审批。
- `refs/tags/v* + prod`：受控正式稳定发布路径，tag 不可移动、覆盖或删除。
- `main + sit`：低频手动验证，基本不参与日常调度。
- `daily-build-*`：每日自动构建入口。
- `uat-daily-build-*`：允许的 UAT 构建、重试与验证入口。
- `release/*`（不含 `release/v*`）：UAT 路径，不得进入 PROD。
- `v*`：只作为 `refs/tags/v*` 的正式稳定发布入口，不得作为日快照输入。

`main`、非 `release/v*` 分支、`daily-build-*`、`uat-daily-build-*`、
`sit-*`、`snapshot-*`、`prod-*` 以及任何其他 tag/branch 都是 PROD 禁止来源。
不能通过 `deploy_env`、`snapshot_tag` 或脚本的前缀推断绕过这一限制。

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
