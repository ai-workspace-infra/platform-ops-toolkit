# VPS 数据迁移模式

`.github/workflows/data-migration.yaml` 支持两种互斥的目标模式：

| 目标配置 | 行为 |
|---|---|
| `accounts_target_backend=vps` + `accounts_migration_mode=data` | **VPS → VPS**：通过 SSH 在两端 PostgreSQL 容器网络中运行 `migratectl`；使用 `accounts_source_host` 和 `accounts_target_host`，不使用 Supabase DSN |
| `accounts_target_backend=supabase` + `accounts_migration_mode=metadata` | **PROD Console → UAT Supabase**：通过 SSH 只读导出 `public` schema，并对 Supabase Target 做只读预检 |
| `accounts_target_backend=supabase` + `accounts_migration_mode=metadata_and_data` | **PROD Console → UAT Supabase**：通过 SSH 只读导出 `public` schema 和业务数据，并一次性写入 Supabase Target |

Supabase 目标已有数据时，`workflow_dispatch` 的
`supabase_target_existing_strategy` 决定写入策略：

| 策略 | 适用场景 | 行为 |
|---|---|---|
| `reject`（默认） | 未确认目标状态 | 目标 `public` 非空即停止，不做写入 |
| `replace_public` | UAT 可废弃、需要重建 | 先用 `pg_dump` 备份目标 `public`，再删除 `public` 对象，最后按 `metadata`/`metadata_and_data` 重建；必须同时将 `supabase_target_confirm_replace=true` |
| `accounts_merge` | UAT 数据必须保留 | 仅允许 `metadata_and_data`；使用 Accounts 专用 `migratectl import --merge --merge-strategy timestamp` 增量合并，不删除目标表或目标行 |

`replace_public` 备份会作为 GitHub Actions artifact 上传，保留 1 天；备份可能包含业务
敏感数据，验证后应及时删除。`accounts_merge` 在实际写入前会先执行一次目标 dry-run，
并在写入后再次 dry-run 验证 users、identities、sessions 没有被重复插入。

VPS → VPS 与 VPS → Supabase 不可混用：前者需要两端 SSH 主机和 `migratectl`，后者需要
PROD 源 SSH 主机、源容器内的 `readonly` 角色和 Supabase 目标 DSN。

Supabase 迁移流程：

```text
PROD PostgreSQL container（SSH + container-local trust，readonly role）
  → SSH 执行 pg_dump public schema metadata
  → SSH 执行 pg_dump public business data
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

kv/data/uat/accounts-migration
  MIGRATION_SOURCE_SSH_PRIVATE_KEY_B64 = <base64 of the dedicated key authorized only for root@console.svc.plus>
```

工作流固定通过 `root@console.svc.plus` 的 SSH 在 `postgresql-svc-plus` 容器内执行
`pg_dump -U readonly -d account`，并将 SQL 流回 Runner；不再通过 Runner 侧 DSN、密码、
数据库端口转发或 stunnel 进行源端认证。容器内 `pg_hba` 的 loopback `trust` 仅跳过密码校验，
`readonly` 角色仍限制源端只能读取。

源容器就绪由 SSH 执行容器内 `pg_isready` 验证。源端密钥必须独立于 UAT 部署密钥，
并仅授予 PROD `console.svc.plus` 所需的访问权限。

Session pooler（`pooler.supabase.com:5432`）适合当前 IPv4 VPS 和迁移 runner，也可以
用于 `pg_dump/psql`。Transaction pooler（端口 `6543`）仅适合短请求应用流量，迁移脚本
会拒绝它。若目标网络可用 IPv6 或已购买 IPv4 add-on，可将
`supabase_target_connection_mode=direct` 并切换到 `DATABASE_DIRECT_URL`。
目标 DSN 会被脚本强制校验为 Supabase 端点，并拒绝 `svc.plus`、Transaction pooler
和同源目标；`PROJECT_REF` 必须与 workflow input 一致。

## 执行顺序

1. 先用 `accounts_target_backend=supabase`、`accounts_migration_mode=metadata`、
   `supabase_target_existing_strategy=reject`、`supabase_metadata_dry_run=true` 做源/目标连接、
   对象完整性和目标状态预检。
2. UAT 可废弃时，选择 `replace_public`，明确设置
   `supabase_target_confirm_replace=true`，先以 dry-run 检查，再将
   `supabase_metadata_dry_run=false` 执行备份、清空和重建。
3. UAT 数据需保留时，选择 `accounts_merge`，并将
   `accounts_migration_mode=metadata_and_data`；先 dry-run，确认合并计划后再关闭 dry-run。

默认策略下目标已有业务表时流水线拒绝隐式覆盖；只有显式选择 `replace_public` 并确认，
才会清空目标 `public`。`accounts_merge` 不执行目标表删除；源端只执行 `pg_dump`，不会执行
源端 DDL 或业务写入。
Content Service 当前是 Git/文件索引模式，没有 PostgreSQL 元数据表，因此不创建虚假
Content 表；它接入 Supabase 运行时时继续保持数据库可选。

业务数据可能包含密码哈希、session、MFA secret 等敏感字段，正式执行前必须完成数据
分类确认。GitHub-hosted runner 只可通过受管 SSH 执行 PROD 源容器内的只读导出；Vault
中的源端 SSH 密钥必须可审计。
VPS 的 Accounts/Billing 运行时
建议使用 Session pooler；只有在应用明确兼容 transaction pooling（关闭 prepared
statement/session state 依赖）时，才考虑 `6543` Transaction pooler。
