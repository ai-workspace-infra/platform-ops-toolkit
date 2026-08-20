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
由工作流建立的本地入口，并要求传入 `supabase_source_tunnel_host`；不要把该本地端口直接当作
GitHub Runner 上天然存在的服务。Serverless Orchestrator 的 UAT 默认源端为
`console.svc.plus`，并默认使用 SSH 将其 `127.0.0.1:5432` 转发到 Runner 的本地入口；这是一条
**PROD → UAT Serverless** 的单向链路。Serverless Orchestrator 强制使用 SSH，防止保存的
dispatch 值意外让 Runner 去连接未发布的 stunnel 端口；stunnel 只保留给直接调用
`data-migration.yaml` 的、网络已明确开放 TLS 端口的其他迁移场景。

隧道就绪是用 `pg_isready` 穿过隧道判定的，不是判断本地端口是否 listen。stunnel 在拨上游之前
就已经把 accept socket bind 好了，所以"端口起来了"和"隧道通了"是两回事：run 32219430536 里
就是本地端口已就绪、上游腿不通，pg_dump 在 10 秒（stunnel 默认 `TIMEOUTconnect`）后才报
`server closed the connection unexpectedly`。探测失败时脚本会把 stunnel 日志整份打出来。
连接超时（而不是 refused）说明报文被丢弃，应先查 VPS 侧防火墙是否放行 GitHub runner 出口，
再考虑 `runner_type=self-hosted`。

可选环境变量 `SUPABASE_SOURCE_TUNNEL_SNI`：stunnel-server 使用 `*.onwalk.net` 公网通配证书并按
SNI 选择服务，平台自身的 client 固定用 `postgresql-<env>.onwalk.net`。设置该变量后，CI 侧
stunnel client 会同时启用 `sni` / `checkHost` / `verifyChain`（CA 默认取
`/etc/ssl/certs/ca-certificates.crt`，可用 `SUPABASE_SOURCE_TUNNEL_CA` 覆盖），从而校验对端身份
而不是盲信隧道端口上的任何应答。不设置则保持不校验的现状行为。

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
分类确认。GitHub-hosted runner 可通过受管 stunnel 访问以 loopback DSN 表示的 VPS 源库；
若网络策略不允许 Runner 访问该 TLS endpoint，再使用 `runner_type=self-hosted`，并确保
runner 同时可达源 VPS 和 Supabase 目标端点。Vault 中的源 DSN 仍必须是可审计的明确来源，
loopback 仅作为由工作流建立 stunnel 的本地入口。VPS 的 Accounts/Billing 运行时
建议使用 Session pooler；只有在应用明确兼容 transaction pooling（关闭 prepared
statement/session state 依赖）时，才考虑 `6543` Transaction pooler。
