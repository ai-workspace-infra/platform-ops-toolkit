# Daily Snapshot 手动执行版

`Daily Main Snapshot` 仅使用 GitHub App 认证。workflow 通过 GitHub OIDC 登录 Vault，读取 App 私钥并按目标组织生成 installation token。

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
github-actions-accounts-daily
github-actions-billing-service-daily
github-actions-docs-daily
github-actions-portal-daily
github-actions-postgresql-daily
```

这些 role 至少需要绑定：

```text
ref = refs/tags/daily-build-*
repository = <service repository>
job_workflow_ref = <service repository>/.github/workflows/ci-pipeline.yml@refs/tags/daily-build-*
```

role 只读构建所需的 Vault 路径，并只允许 `sit` / `uat` 的 GHCR 或制品发布路径。
不要把 `daily-build-*` 加入生产 `v*` role。

如果服务 workflow 仍使用 `workflow_dispatch` 而不是 tag push，还必须让它显式使用
`daily-build-*` 作为 checkout ref、镜像 tag、binary/zip 名称和 chart version。
