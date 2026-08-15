# Vault CICD 凭据迁移 TL;DR

## 结论

`kv/CICD/details` 不是实际存在的 secret path。当前可读取的源路径是：

```text
Mount:  kv
Path:   CICD
Version: 40
CLI:    kv/CICD
API:    /v1/kv/data/CICD?version=40
```

因此不要使用 `kv/CICD/details`。

## 执行脚本

脚本位置：

```text
scripts/vault/vault_migrate_cicd_details.sh
```

先执行 dry-run：

```bash
cd /Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit

./scripts/vault/vault_migrate_cicd_details.sh \
  --token "$VAULT_TOKEN" \
  --source-path=kv/CICD \
  --source-version=40
```

推荐使用交互输入 token，避免把 token 放进 shell history：

```bash
export VAULT_ADDR=https://vault.svc.plus
read -rsp 'Vault token: ' VAULT_TOKEN
printf '\n'
export VAULT_TOKEN

./scripts/vault/vault_migrate_cicd_details.sh \
  --source-path=kv/CICD \
  --source-version=40
```

确认 dry-run 输出后才执行写入：

```bash
./scripts/vault/vault_migrate_cicd_details.sh \
  --source-path=kv/CICD \
  --source-version=40 \
  --apply
```

## 默认迁移规则

公共凭据写入 `kv/CICD`：

```text
GHCR_USERNAME
GHCR_TOKEN
ROOT_BOOTSTRAP_PASSWORD
```

基础设施凭据写入三个环境路径：

```text
kv/CICD/sit
kv/CICD/uat
kv/CICD/prod
```

包含：

```text
SSH_PRIVATE_DEPLOY_KEY_B64
VULTR_API_KEY
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
TF_STATE_REGION
```

## 未分类 key

脚本发现未分类 key 时会停止，即使带了 `--apply` 也不会写入。当前未分类项包括 Cloudflare、GPG、NPM、备份、服务 token 和非 B64 SSH key 等凭据。

这是故意的：这些 key 的环境归属在仓库文档中尚未确认，不能直接复制到三个环境。

如果本次目标只是先补齐 workflow 所需的基础凭据，可以让未分类 key 留在源路径，继续迁移已确认的 key：

```bash
./scripts/vault/vault_migrate_cicd_details.sh \
  --source-path=kv/CICD --source-version=40 \
  --unclassified-to=leave --apply
```

只有确认未分类 key 暂时复用同一份值时，才允许选择以下策略：

```bash
# 写入公共路径；仅适用于确认三环境共用的凭据
./scripts/vault/vault_migrate_cicd_details.sh \
  --source-path=kv/CICD --source-version=40 \
  --unclassified-to=shared --apply

# 写入 sit/uat/prod；只是路径隔离，值仍然相同
./scripts/vault/vault_migrate_cicd_details.sh \
  --source-path=kv/CICD --source-version=40 \
  --unclassified-to=envs --apply
```

`--unclassified-to=envs` 不等于真正的凭据隔离。生产使用前，应替换为独立的 Cloudflare、Vultr、SSH 和服务 token。

## 安全约束

- 脚本默认 dry-run，必须显式使用 `--apply` 才写 Vault。
- 默认跳过目标路径中已存在的 key；`--force` 才会覆盖。
- 不删除 `kv/CICD` 源路径，也不删除 version 40。
- 不打印 secret value，只打印路径、版本和 key 名。
- 通过 `--token TOKEN` 传参会暴露在 shell history/进程参数中，优先使用交互输入。
- 已经在终端或聊天中暴露的 Vault Token 必须撤销并重新生成。

## 写入后检查

只检查 key 名，不输出值：

```bash
for path in kv/CICD kv/CICD/sit kv/CICD/uat kv/CICD/prod; do
  vault kv get -format=json "$path" \
    | jq -r --arg path "$path" '"\($path): " + ((.data.data // {}) | keys | join(","))'
done
```
