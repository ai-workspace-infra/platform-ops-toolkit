# Supabase Account DB 初始化

Supabase 项目与数据库密码只从 Vault server KV 读取，执行环境通过外部参数选择，
不在脚本、YAML、Terraform tfvars 或 GitHub Actions 参数中写入密码。

## Vault 路径

源路径（KV v2 CLI 写法）：

```text
kv/<env>/serverless/supabase
  PROJECT_REF
  DATABASE_PASSWORD                 # 可选；如果没有，则从 DATABASE_DIRECT_URL 提取
  DATABASE_USERNAME                 # 可选；没有则从 URI 解析
  DATABASE_NAME                     # 可选；没有则从 URI 解析，通常是 postgres
  DATABASE_SESSION_POOLER_URL       # 运行时 URI，优先使用
  DATABASE_DIRECT_URL                # DDL/迁移 URI，也可携带密码
```

结果合并写入：

```text
kv/<env>/databases
  account_supabase_project_ref
  account_supabase_database_password
  account_database_username
  account_database_name
  account_database_uri
  account_database_direct_uri
```

已有 `account_pg_password` 默认不会被覆盖；只有显式指定
`--write-account-password` 才会把 Supabase 密码同步到这个兼容键。

`<env>` 由 `--env dev|sit|uat|prod` 或 `VAULT_ENV_PATH` 传入。用户可见的 serverless
workflow 当前提供 `dev|uat|prod`，保留 `sit` 是为了兼容平台现有 Vault policy。

## 执行

只读检查：

```bash
VAULT_ADDR=https://vault.svc.plus \
  ./scripts/serverless_uat/init_supabase_account_db.sh --env uat --dry-run
```

标准 IAC init（`iac_modules` 已 checkout 到 `infra/iac_modules`）：

```bash
VAULT_ADDR=https://vault.svc.plus \
  ./scripts/serverless_uat/init_supabase_account_db.sh \
  --env uat \
  --iac-root "$PWD/infra/iac_modules"
```

如需灌入 Accounts 基线 schema，额外传入 schema 文件；脚本会使用 Vault URI 建立
连接，不会把 URI 放到命令参数或日志中。IPv4-only 的 GitHub-hosted runner 会优先
使用 `DATABASE_SESSION_POOLER_URL`，没有 Session URI 时才回退到 `DATABASE_DIRECT_URL`：

```bash
./scripts/serverless_uat/init_supabase_account_db.sh \
  --env uat \
  --schema-file /path/to/accounts/sql/schema.sql
```

脚本将 Supabase URI 中的实际数据库名写入 `account_database_name`（通常为 `postgres`），
将 `account` 作为 Accounts 服务的逻辑数据库契约。Supabase Cloud 单项目并不支持把项目默认数据库随意改名为
`account`；如果必须满足 `account_user` 最小权限模型，应在 Supabase 数据库中另行执行
受审计的 role/grant SQL，不能由 Supabase Terraform provider 假定自动创建。
