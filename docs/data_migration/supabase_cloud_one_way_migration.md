# VPS 数据迁移模式

`.github/workflows/data-migration.yaml` 支持两种互斥的目标模式：

| 目标配置 | 行为 |
|---|---|
| `accounts_target_backend=vps` + `accounts_migration_mode=data` | **VPS → VPS**：通过 SSH 在两端 PostgreSQL 容器网络中运行 `migratectl`；使用 `accounts_source_host` 和 `accounts_target_host`，不使用 Supabase DSN |
| `accounts_target_backend=supabase` + `accounts_migration_mode=metadata` | **VPS → Supabase**：通过 stunnel 从 VPS 只读导出 schema，并对 Supabase 目标做只读预检 |
| `accounts_target_backend=supabase` + `accounts_migration_mode=metadata_and_data` | **VPS → Supabase**：通过 stunnel 从 VPS 导出 `public` schema 和业务数据，并一次性写入 Supabase |

VPS → VPS 与 VPS → Supabase 不可混用：前者需要两端 SSH 主机和 `migratectl`，后者需要
只读源 DSN、Supabase 目标 DSN 和（源 DSN 为 loopback 时）`supabase_source_tunnel_host`。

Supabase 迁移流程：

```text
VPS PostgreSQL（只读 source DSN）
  → pg_dump public schema metadata
  → pg_dump public business data
  → target preflight
  → schema + data 同一事务写入
  → schema/data SHA-256 marker 收敛校验
Supabase Cloud（直连 target DSN）
```

## Vault 配置

通过 GitHub OIDC → Vault 注入，不使用 GitHub Actions Secrets：

```text
kv/data/<env>/serverless/supabase
  PROJECT_REF          = rbjnksmfzkjheiwpkaem
  DATABASE_SESSION_POOLER_URL = postgres://postgres.rbjnksmfzkjheiwpkaem:...@aws-0-<region>.pooler.supabase.com:5432/postgres
  DATABASE_DIRECT_URL         = postgres://postgres:...@db.rbjnksmfzkjheiwpkaem.supabase.co:5432/postgres

kv/data/<env>/accounts-migration
  MIGRATION_SOURCE_DSN = postgres://readonly:...@<vps-postgres-host>:5432/account?sslmode=require
```

若 `MIGRATION_SOURCE_DSN` 使用 `127.0.0.1`、`localhost` 或 `::1`，工作流会将其视为
受管 stunnel 客户端入口，并要求传入 `supabase_source_tunnel_host`。该客户端会在 Runner
中启动，并转发到 `<host>:15433`；不要把本地端口直接当作 GitHub Runner 上天然存在的服务。
对于 UAT selfhost 数据源，Serverless Orchestrator 使用
`accounts-vps-uat.onwalk.net:15433` 作为 TLS tunnel target。

Session pooler（`pooler.supabase.com:5432`）适合当前 IPv4 VPS 和迁移 runner，也可以
用于 `pg_dump/psql`。Transaction pooler（端口 `6543`）仅适合短请求应用流量，迁移脚本
会拒绝它。若目标网络可用 IPv6 或已购买 IPv4 add-on，可将
`supabase_target_connection_mode=direct` 并切换到 `DATABASE_DIRECT_URL`。
目标 DSN 会被脚本强制校验为 Supabase 端点，并拒绝 `svc.plus`、Transaction pooler
和同源目标；`PROJECT_REF` 必须与 workflow input 一致。

## 执行顺序

1. 先用 `accounts_target_backend=supabase`、`accounts_migration_mode=metadata`、
   `supabase_metadata_dry_run=true` 做源/目标连接、对象完整性和目标空库预检。
2. 确认目标项目 `public` schema 没有业务表后，使用
   `accounts_migration_mode=metadata_and_data`、仍保持 dry-run 做业务数据导出预检。
3. 审核导出范围后，才将 `supabase_metadata_dry_run` 改为 `false` 执行一次性迁移。

目标已有业务表时流水线拒绝隐式覆盖；源端只执行 `pg_dump`，不会执行 DDL 或业务写入。
Content Service 当前是 Git/文件索引模式，没有 PostgreSQL 元数据表，因此不创建虚假
Content 表；它接入 Supabase 运行时时继续保持数据库可选。

业务数据可能包含密码哈希、session、MFA secret 等敏感字段，正式执行前必须完成数据
分类确认。若 GitHub hosted runner 无法访问 VPS PostgreSQL，使用 `runner_type=self-hosted`，
并确保 runner 同时可达源 VPS 和 Supabase 目标端点，且 Vault 中仍使用可明确审计的源库
地址而非 Runner loopback。VPS 的 Accounts/Billing 运行时
建议使用 Session pooler；只有在应用明确兼容 transaction pooling（关闭 prepared
statement/session state 依赖）时，才考虑 `6543` Transaction pooler。
