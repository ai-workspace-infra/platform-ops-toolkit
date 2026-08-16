# VPS → Supabase Cloud 单向数据库迁移

`.github/workflows/data-migration.yaml` 支持两条互斥路径：

| 目标配置 | 行为 |
|---|---|
| `accounts_target_backend=vps` + `accounts_migration_mode=data` | 保留现有 VPS 自建 PostgreSQL `migratectl` 数据迁移 |
| `accounts_target_backend=supabase` + `accounts_migration_mode=metadata` | 只导出元数据并对 Supabase 目标做只读预检 |
| `accounts_target_backend=supabase` + `accounts_migration_mode=metadata_and_data` | VPS → Supabase 单向复制 `public` schema 元数据和业务数据 |

默认仍是第一条 VPS 路径，不改变现有 `platform-ops.yaml` 的调用行为。

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
  DATABASE_DIRECT_URL  = postgres://...@db.rbjnksmfzkjheiwpkaem.supabase.co:5432/postgres

kv/data/<env>/accounts-migration
  MIGRATION_SOURCE_DSN = postgres://readonly:...@<vps-postgres-host>/account
```

`DATABASE_POOLER_URL` 仅供应用运行时连接；迁移必须使用 `DATABASE_DIRECT_URL`。
目标 DSN 会被脚本强制校验为 Supabase 直连端点，并拒绝 `svc.plus`、Pooler 和同源
目标。`PROJECT_REF` 必须与 workflow input 一致。

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
并确保 runner 同时可达源 VPS 和 Supabase 直连端点。
