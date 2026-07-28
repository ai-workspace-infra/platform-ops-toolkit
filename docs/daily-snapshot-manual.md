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

workflow 会创建当天的 `daily-build-YYYY.MM.DD` tag，并继续执行目标仓库的构建触发流程。

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
