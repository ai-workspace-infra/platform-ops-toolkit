# Stripe 套餐目录初始化 TL;DR

## 结论

部署**新环境**时，不要手工在 Stripe Dashboard 创建 Product、Price 或 Webhook。
套餐定义来自 `ai-workspace-services/accounts/scripts/stripe-catalog.yaml`；发布编排会在
Accounts、数据库和公网域名健康后自动完成以下操作：

1. 新数据库没有 `PRO-MONTHLY` 时写入幂等套餐种子；
2. 创建或复用 Stripe Product、Price 和 Webhook；
3. 把实际 Stripe `price_*`、`priceAmount`、`priceCurrency`、`priceUnit` 回写到
   Accounts 的 `billing_plans`；
4. 失败即让部署失败，避免出现 Stripe 已有价格但应用目录没有对应记录的半成品状态。

Serverless 入口是 `serverless-orchestrator.yml` 的 `Stripe / Catalog Bootstrap` job；
self-hosted 入口是 `selfhost-orchestrator.yml` 的 `[4] Stripe catalog` job。

## Vault 前置条件

只允许从目标环境 Vault 路径读取，不将以下值放入 Git、workflow input、脚本或聊天记录：

```text
kv/<env>/billing-service
  SANDBOX_STRIPE_SECRET_KEY       # UAT/SIT 使用 sk_test_
  SANDBOX_STRIPE_WEBHOOK_SECRET   # UAT/SIT webhook secret
  STRIPE_XCONNECT_PAY_URL         # 同环境 Payment Link

kv/prod/billing-service
  PROD_STRIPE_SECRET_KEY          # 生产独立 sk_live_
  PROD_STRIPE_WEBHOOK_SECRET      # 生产 webhook secret
  STRIPE_XCONNECT_PAY_URL          # 生产 Payment Link

kv/CICD
  ROOT_BOOTSTRAP_EMAIL    # 可选；默认 admin@svc.plus
  ROOT_BOOTSTRAP_PASSWORD # 仅用于编排临时登录 Accounts 管理 API
```

发布工作流通过 GitHub OIDC 获取临时 Vault token；它不会保存
`ACCOUNTS_ADMIN_TOKEN`。自动化登录产生的 Accounts token 只存在于该 job 进程中。
因此 bootstrap 管理员不能开启 MFA；日常运营管理员应使用独立、启用 MFA 的账号。

## 人工补救命令

只有在需要重新同步、且自动编排不可用时才执行。以下是正确的 shell 格式：URL 是普通
字符串，反斜杠必须位于每一行末尾。

```bash
cd /Users/shenlan/workspaces/ai-workspace-services/accounts

STRIPE_SECRET_KEY='从 Vault kv/uat/billing-service/SANDBOX_STRIPE_SECRET_KEY 读取' \
ACCOUNTS_ADMIN_TOKEN='短期 Accounts 管理员会话 token' \
ACCOUNTS_BASE_URL='https://accounts-cloudflare-uat.onwalk.net' \
scripts/stripe-sync-catalog.sh \
  --env uat \
  --domain-base onwalk.net \
  --write-catalog
```

该命令会创建或复用 Stripe 对象，并通过 Accounts admin API 回写目录。它不会把 token
或 Stripe key 写入文件。先用 `--dry-run` 审核会执行的操作；生产改为 `--env prod`、
生产域名和 `kv/prod/billing-service/PROD_STRIPE_SECRET_KEY` 的独立 `sk_live_`。

## 合并与发布顺序

1. 合并 Accounts 的价格字段、种子和同步脚本；
2. 合并 playbooks 的新库套餐种子；
3. 合并本仓库发布编排；
4. 执行 schema 初始化，再执行完整 deploy 或 deploy+migrate。

Stripe Price 金额不可原地修改。变价时新增 `lookup_key`，重新同步后停用旧 Price；不要在
Stripe Dashboard 手工修改目录对象。
