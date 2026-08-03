# Web SaaS 只读 Source → Target 单向迁移规划

> 状态：规划阶段，不执行迁移、不创建生产用户、不修改生产节点。
>
> 目标：把 Accounts 现有导出/导入能力接入
> `.github/workflows/data-migration.yaml`，形成可审计、可重复、单向的
> web-saas 用户迁移流程。

## 1. 不可违反的边界

迁移方向固定为：

```text
Source web-saas PostgreSQL
  └─ SSH key-only readonly + PostgreSQL role readonly（只读）
       ↓ 仅导出
加密快照 / 受控传输
       ↓ 仅导入
Target web-saas PostgreSQL
  └─ 独立的目标写入凭据
```

- Source 永远使用 Linux `readonly` 用户登录；禁止 root、sudo、密码登录和
  SSH agent/tunnel 转发。
- Source PostgreSQL 使用同名 `readonly` role，独立数据库密码，不复用 SSH
  私钥；权限覆盖目标迁移所需的全部数据库对象，但只有 `CONNECT`、schema
  `USAGE`、表/序列 `SELECT`。
- Workflow 不把数据库密码、SSH 私钥或快照内容写入日志、GitHub input、artifact
  名称或 PR 描述。凭据只通过 GitHub OIDC → Vault 注入。
- Source 只执行 `SELECT`/导出；任何 `INSERT`、`UPDATE`、`DELETE`、DDL 只允许
  在 Target 侧执行。
- 默认只迁移 `public.users` 的业务身份字段及 UUID 关联数据；不迁移
  `sessions`、MFA secret、billing、Xray 节点运行时状态，除非后续单独审批。

## 2. 现有实现盘点

Accounts 已有 `cmd/migratectl`、`internal/migrate` 和 `make account-export` /
`make account-import`：

- 导出器当前从 `public.users` 读取 username、email、password hash、role、
  groups、permissions 和审计时间；密码字段是 bcrypt/同类哈希，不是明文密码。
- 当前 `UserRecord` 没有完整承载 `users.proxy_uuid`，而数据库模型同时存在
  `users.uuid` 与 `users.proxy_uuid`。迁移必须明确保存二者，并在导入前校验
  `proxy_uuid = uuid` 的项目约束，避免 Xray 配置和 Portal QR 再次漂移。
- 当前导出器还会读取 identities/sessions；这与“只迁移 web-saas 用户身份”的
  最小目标不一致，正式实现应增加字段范围/资源范围开关，默认关闭 sessions。
- 当前 `config/sync.yaml` 的 remote 示例使用 `root`，不能作为正式 Source 迁移
  配置；迁移专用配置必须改为 `readonly`，并让数据库 DSN 使用 Vault 注入的
  `readonly` role。
- `data-migration.yaml` 已具备 OIDC/Vault、部署 SSH key、`toolkit_ref` /
  `infra_ref` 和 `toolkit_action`，但 Source/Target 主机及迁移范围主要依赖
  `PROVISION_*` 环境变量，输入契约不透明；需要显式化并在 workflow 前置校验。

## 3. Accounts 侧最小改造

### 3.1 Snapshot schema

扩展 `UserRecord`：

```yaml
uuid: <users.uuid>
proxyUuid: <users.proxy_uuid>
username: ...
email: ...
password: <password hash only>
...
```

导出 SQL 必须显式列出 `proxy_uuid`，不能使用 `SELECT *`。导入时：

1. 校验 `uuid` 和 `proxyUuid` 都是合法 UUID。
2. 默认要求 `proxyUuid == uuid`；不一致记录为阻断性冲突，不自动生成新 UUID。
3. 以 `uuid` 作为用户主键 upsert，写入同一个 `proxy_uuid`。
4. 目标已存在同 UUID 但 email/username 冲突时停止，不覆盖并生成审计报告。
5. 导入事务提交前执行一致性查询：`users.proxy_uuid = users.uuid`、数量、快照
   digest 和目标写入数量必须全部通过。

### 3.2 单向模式

为 `migratectl` 增加明确模式，而不是让 `push`/`pull`/`mirror` 语义隐式决定
方向：

- `source-export`：只打开 source DSN，执行导出和校验，输出快照。
- `target-import`：只打开 target DSN，执行 dry-run 或事务导入。
- `mirror` 继续保留兼容性，但在本迁移 workflow 中禁止使用。

导出快照需要：0600 文件权限、SHA-256 digest、记录 schema hash、source 标识、
导出时间、用户数量和字段范围。若跨网络传输，使用 SFTP/SSH 或 Vault 支持的
加密对象存储；禁止明文 HTTP 上传。

## 4. `data-migration.yaml` 接入方案

### 4.1 显式 workflow inputs

在 `workflow_dispatch` 和 `workflow_call` 同步增加：

| Input | 说明 | 默认/约束 |
|---|---|---|
| `source_host` | Source 主机或域名 | 必填，禁止生产默认值 |
| `target_host` | Target 主机或域名 | 必填 |
| `source_db_name` | Source 数据库 | `account` |
| `target_db_name` | Target 数据库 | `account` |
| `migration_scope` | 字段范围 | `web-saas-users` |
| `email_keyword` | 可选邮箱过滤 | 默认空；生产需 allowlist |
| `dry_run` | 仅校验不写入 Target | UAT 默认 `true` |
| `allowlist` | 明确 UUID 列表 | 与 email 过滤至少一个约束 |

Source 用户名固定为 `readonly`，不可作为普通 input 覆盖。Target 写入账号由
Vault 提供，不能用 Source 的 `readonly` role。

### 4.2 Vault 读取约定

使用环境隔离路径，例如 `kv/data/uat/databases`：

- `readonly_pg_password`：Source PostgreSQL `readonly` role 密码；
- `account_pg_password`：仅作为 Target 侧的既有应用/写入凭据，具体使用权限
  由目标部署契约决定；
- `SSH_PRIVATE_DEPLOY_KEY_B64`：仅用于 SSH key-only 通道；不作为数据库密码。

若 Vault 尚无 `readonly_pg_password`，先完成 UAT role 创建和 secret 写入，再
运行迁移 dry-run；不得用 `account_pg_password` 冒充 source readonly 密码。

### 4.3 Workflow 阶段

```text
validate inputs
  → OIDC 登录 Vault（source/target secret 隔离）
  → 配置 readonly SSH key + known_hosts
  → source preflight（whoami、sshd 约束、PG CONNECT/SELECT 探针）
  → source-export（不写 source）
  → digest/schema/UUID 一致性校验
  → 加密 artifact / SFTP 传输
  → target-import --dry-run
  → 人工审批（生产）或 UAT 自动继续
  → target-import 事务写入
  → target postflight + 审计报告
```

Workflow 中的 shell 逻辑继续放在 `.github/scripts/`，YAML 只负责调用脚本。
每个阶段输出数量、digest、目标和结果，不输出账号密码、哈希、token、私钥或
快照正文。

## 5. UAT 验证顺序

1. 在 UAT 创建 `readonly` Linux 用户：同 root 的 public key、锁定密码、无 sudo、
   无 docker/adm 等特权组。
2. 创建同名 PostgreSQL `readonly` role，并对所有 web-saas 共享库授予只读权限。
3. 用 `readonly` SSH + `readonly` DSN 执行 source preflight；反向执行写入探针，
   必须失败并记录为通过。
4. 只导出一个 allowlist UUID，检查 `uuid`、`proxyUuid`、email、password hash
   和 digest；不得出现 sessions/MFA/billing 数据。
5. Target dry-run 检查冲突，人工确认后导入一个 UAT 账号。
6. 检查 Xray 配置、Portal QR 与 `users.uuid` 一致；再扩展到全量 UAT 用户。
7. 验证重复运行是幂等的，Source 没有 UPDATE/DDL，Target 有完整审计记录。

## 6. 生产启用门槛

- UAT 连续通过全量 dry-run、单用户导入、重复导入和回滚演练。
- Source/Target 角色权限快照已保存，确认 Source `readonly` 无写权限。
- Workflow 的 `vault_env_path=prod` 必须显式审批；禁止把 UAT secret、host、
  allowlist 或 artifact 复用到生产。
- 首次生产迁移只允许 allowlist UUID，禁止全量；完成核对后才可扩大范围。

## 7. 待实现清单

- [ ] Accounts：增加 `proxy_uuid` 快照字段、导入一致性校验和冲突阻断。
- [ ] Accounts：增加 `source-export` / `target-import` 单向模式，默认排除
  sessions/MFA。
- [ ] Platform Ops：把 source/target/范围/dry-run 显式化为 workflow inputs。
- [ ] Platform Ops：把 source readonly DSN、target 写入 DSN、artifact digest
  和审计报告接入 Vault/Actions artifact。
- [ ] Playbooks：在 UAT 主机通过 `roles/readonly_ssh_user` 创建普通 Linux
  `readonly` 与 PostgreSQL `readonly`，默认不启用生产。
- [ ] UAT：完成 preflight、单用户 dry-run、单向导入、幂等和权限反向验证。

