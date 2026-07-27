# Daily Snapshot 手动执行版

不使用 GitHub App、Vault 或 `CROSS_REPO_GH_TOKEN`。直接使用本机 GitHub CLI 登录态执行现有 tag 脚本。

## 执行步骤

在 `platform-ops-toolkit` 仓库目录执行：

```bash
gh auth login
GH_TOKEN="$(gh auth token)" \
DEPLOY_ENV=uat \
SNAPSHOT_TAG="daily-build-$(date -u +%Y.%m.%d)" \
SNAPSHOT_ORGS="ai-workspace-infra,ai-workspace-lab,ai-workspace-services,ai-workspace-xstream" \
.github/scripts/tag-daily-main-snapshot.sh
```

脚本会创建当天的 `daily-build-YYYY.MM.DD` tag，并继续执行目标仓库的构建触发流程。

## 常用调整

指定环境：

```bash
DEPLOY_ENV=uat
```

指定单个组织：

```bash
SNAPSHOT_ORGS=ai-workspace-services
```

指定仓库：

```bash
SNAPSHOT_REPOS=accounts,artifacts
```

自定义 tag：

```bash
SNAPSHOT_TAG=daily-build-2026.07.27
```

## 权限要求

`gh auth login` 使用的账号必须拥有目标组织仓库的写权限，并且允许创建 tag、读取仓库内容，以及触发目标 workflow。不要把登录 token 写入仓库文件或 GitHub Actions 日志。
