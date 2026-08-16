# Supabase 调试环境 Vault 初始化 TL;DR

## 当前项目

调试环境按 `dev` 管理，对应 Supabase 项目：

```text
project_ref: iqkxspmhcfqmhkbjdoms
region:      ap-northeast-1 (Tokyo)
database:    postgres
username:    postgres
```

## Vault 路径

```text
kv/dev/serverless/supabase
```

已初始化以下 key：

```text
PROJECT_REF
DATABASE_PASSWORD
DATABASE_USERNAME
DATABASE_NAME
DATABASE_SESSION_POOLER_URL
DATABASE_DIRECT_URL
```

已补全：

```text
PROJECT_REF       ✅
DATABASE_USERNAME ✅ postgres
DATABASE_NAME     ✅ postgres
```

待补全：

```text
DATABASE_PASSWORD
DATABASE_SESSION_POOLER_URL
DATABASE_DIRECT_URL
```

不要把密码或完整 URI 写入 Git、Terraform tfvars、聊天记录或 CI 日志。

## URI 使用约定

```text
DATABASE_SESSION_POOLER_URL  应用运行时，优先使用 Session pooler
DATABASE_DIRECT_URL           Terraform/DDL/迁移/备份使用 Direct connection
```

Supabase 单项目实际数据库通常是 `postgres`；`account` 是 Accounts 服务的逻辑名称，
不是通过 Terraform provider 自动创建的第二个数据库。

## 补全后初始化

在已认证的 Vault CLI 会话中执行：

```bash
cd /Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit

VAULT_ENV_PATH=dev \
  ./scripts/serverless_uat/init_supabase_account_db.sh \
  --env dev \
  --iac-root /path/to/iac_modules \
  --schema-file /path/to/ai-workspace-service/accounts/sql/schema.sql
```

脚本会从 `kv/dev/serverless/supabase` 读取 project/password/URI，执行标准 Terraform
`init`，可选执行 Accounts schema，然后将连接契约合并写入：

```text
kv/dev/databases
```

默认不会覆盖已有 database key；需要轮换时才使用 `--force`。完成后应轮换曾经暴露在
终端或聊天中的 Vault token。
