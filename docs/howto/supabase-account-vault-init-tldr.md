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
  PROJECT_URL
  REGION
  DATABASE_PASSWORD
DATABASE_USERNAME
DATABASE_NAME
DATABASE_SESSION_POOLER_URL
DATABASE_DIRECT_URL
```

已补全：

```text
PROJECT_REF       ✅
PROJECT_URL       ✅ https://iqkxspmhcfqmhkbjdoms.supabase.co
REGION            ✅ ap-northeast-1
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

## UAT 当前状态

2026-08-16 已成功执行：

```bash
bash scripts/serverless_uat/init_supabase_account_db.sh \
  --env uat \
  --write-account-password
```

结果已合并写入 `kv/uat/databases`。由于目标已有 `account_pg_password`，脚本默认保留
原值，没有覆盖它；本次命令也没有执行 Terraform init 或 schema migration。schema 初始化
优先使用 IPv4 可达的 `DATABASE_SESSION_POOLER_URL`，没有 Session URI 时才使用
`DATABASE_DIRECT_URL`。

从 Supabase Connect 页面复制的 URI 若仍带 `[YOUR-PASSWORD]`，脚本会用 Vault 中的
`DATABASE_PASSWORD` 临时补全；真实密码缺失时会拒绝初始化，避免把占位符写入连接契约。
目标 Vault key 已存在时仍保持幂等；仅检测到 `YOUR-PASSWORD` 占位符才会自动修复，真实值不会被覆盖。

## Workflow 验证

`.github/workflows/serverless-orchestrator.yml` 的 `operation=init-schema` 提供独立的
schema 初始化 job。它只 checkout Accounts schema、读取 Vault 并执行 schema 初始化和
连通性校验；不会同时触发 Cloud Run 或 Cloudflare 部署。

手动验证：

```bash
gh workflow run serverless-orchestrator.yml \
  --ref main \
  -f operation=init-schema \
  -f vault_env_path=uat \
  -f accounts_schema_ref=main
```

Workflow 使用 GitHub OIDC + `hashicorp/vault-action` 获取临时 Vault token，不依赖
`secrets.VAULT_TOKEN`。
