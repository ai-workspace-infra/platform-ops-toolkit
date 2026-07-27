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

GitHub App `daily-snapshot-tag`（App ID `4405266`）需要安装到四个目标组织，并拥有目标仓库的：

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
