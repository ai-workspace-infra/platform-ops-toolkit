# PROD 至 UAT Accounts 账号数据单向增量迁移方案与操作指南

本文档记录 PROD 环境至 UAT 环境仅针对 `accounts` 账号中心模块的单向增量迁移方案、安全防呆设计及具体执行步骤。

---

## 1. 架构与迁移范围

- **源环境 (PROD Source)**:
  - 主机: web-saas 节点（`groups: [web_saas, debian, database]`），对外站点 `console.svc.plus`
  - 数据库入口: **`postgresql-saas.svc.plus:5432`**
    （IaC `vultr-vps/config/resources/prod/web-saas.yaml` 的 `service_domains`）
  - 容器名: **`web-saas-postgresql`**（playbooks `roles/readonly_ssh_user/defaults/main.yml`
    与 `initialize-web-saas-schemas.yml` 的一致取值）
  - 数据库/属主: `account` / `account_user`
- **目标环境 (UAT Target)**:
  - 主机: 同形态的 UAT web-saas 节点，对外站点 `console-uat.onwalk.net` / `accounts-uat.onwalk.net`
  - 数据库入口: **`postgresql-saas-uat.onwalk.net:5432`**
    （`resources/uat/web-saas.yaml` 的 `service_domains`）
  - 数据库/属主: `account` / `account_user`

> **不要把 `agent-proxy.onwalk.net` 当成数据库端点。** CMDB 与 IaC 都显示它的
> `groups` 是 `[agent_proxy, debian]`——**没有 `database`**，`service_domains` 也只有
> `agent-proxy.<base>` 一条，那台机器上根本没有 PostgreSQL。
>
> 同样地，`postgresql-platform.<base>` 是 **infra-platform 主机**的服务域名
> （`resources/prod/infra-platform.yaml`），不是 web-saas 栈的 accounts 库，
> 也不是容器名。accounts 的库一直在 web-saas 节点的 `web-saas-postgresql` 容器里。
- **迁移范围**:
  - **仅迁移 `accounts` 模块**的数据（包含用户 `users`、身份 `identities`、会话 `sessions` 等）。
  - 使用 `accounts` 服务内置的 `migratectl` CLI 工具。

### 1.1 UUID 语义约定

- `users.uuid` 是账户内部不可变身份标识，只用于 Accounts 内部关系，不作为代理凭据，也不展示给用户。
- `users.proxy_uuid` 是可轮换的代理凭据。Portal 二维码、Accounts Agent 下发给 Xray、运行态 Xray 客户端以及账户概览统一使用它。
- PROD→UAT 迁移必须使用 `--regenerate-user-uuids`：保留快照中的 `proxy_uuid`，为目标用户分配新的 `users.uuid`，并在同一事务中重写依赖 `users.uuid` 的关联数据。

---

## 2. 4 层防呆设计 (Safeguard / Anti-Foolishness)

为绝对防止 UAT 测试环境的数据反向覆盖或写入 PROD 生产环境，实施以下 4 层防呆屏障：

| 防呆层级 | 防御手段 | 效果 |
| :--- | :--- | :--- |
| **1. PROD DB 内核级只读** | PostgreSQL 角色配置为 `NOSUPERUSER NOCREATEDB NOCREATEROLE`，且仅赋予 `SELECT, USAGE` 权限 | 任意 `INSERT/UPDATE/DELETE` 将被 Postgres 引擎直接拒绝 (`permission denied`) |
| **2. Linux 账号提权隔离** | Linux `readonly` 账号不加入 `sudo`、`wheel`、`docker` 等提权组 | 无法通过 `docker exec` 或宿主机文件操作变动容器或系统配置 |
| **3. CLI 脚本断路熔断** | `accounts_data_migration.sh` 内置硬性字符串断言 | 若 `MIGRATION_TARGET_DSN` 包含 PROD 域名 (`svc.plus`)、不含 UAT 域名 (`onwalk.net` / 本地回环)、或与源 DSN 完全相同，脚本在**接触任何数据库之前** `exit 1` |
| **4. Vault JWT 凭据隔离** | PROD Vault Role 仅在 CI/CD 中解密只读账号密码 | 迁移流水线无法获取 PROD 数据库的写管理员账号密码 |

---

## 3. PROD 只读用户配置方案 (Playbook)

在 PROD web-saas 节点（承载 `console.svc.plus` / `postgresql-saas.svc.plus` 的那台）上，
通过 `playbooks/roles/readonly_ssh_user` 自动部署：

### 3.1 Playbook 文件位置
- Playbook: `playbooks/create_readonly_ssh_user.yml`（`hosts: all`，用 `--limit` 指定目标主机）
- Ansible Role: `playbooks/roles/readonly_ssh_user`

### 3.2 变量与配置说明
该 playbook 的变量全部从**环境变量**读取（见文件顶部 `vars:` 块），不是在 play 里写死的 role vars：

```bash
READONLY_SSH_USER_NAME=readonly \
READONLY_SSH_USER_PUBLIC_KEY="$(cat ~/.ssh/readonly.pub)" \
READONLY_SSH_MANAGE_POSTGRESQL=true \
READONLY_SSH_POSTGRES_CONTAINER=web-saas-postgresql \
READONLY_SSH_POSTGRES_DATABASES=account \
READONLY_SSH_POSTGRES_DEFAULT_PRIVILEGE_OWNERS=account_user \
READONLY_SSH_POSTGRES_PASSWORD="<从 Vault 取>" \
  ansible-playbook -i ../cmdb/inventory.ini create_readonly_ssh_user.yml \
    --limit <PROD web-saas 主机>
```

注意几个容易写错的点：

- 环境变量是 `READONLY_SSH_POSTGRES_CONTAINER`，**不是** `..._POSTGRESQL_CONTAINER_NAME`。
- `READONLY_SSH_POSTGRES_DATABASES` 的默认值是
  `account,gitea,litellm,rag,vault_storage,zitadel,postgres` 一整串——只做 accounts 迁移时
  显式收窄成 `account`，避免给只读账号多授权无关库。
- PostgreSQL 集成是 opt-in（`READONLY_SSH_MANAGE_POSTGRESQL`），DB 口令必须由 Vault/Ansible
  变量提供（`READONLY_SSH_POSTGRES_PASSWORD`），**不得**与 SSH 密钥同源。
- `--limit` 的值取 CMDB 里的主机名，不要写服务域名。

---

## 4. Accounts 单向迁移执行流程 (`migratectl`)

### 4.1 导出 PROD 端快照 (Export)
在具备 `migratectl` 工具的环境或 runner 上，连通 PROD 只读 DB：
```bash
migratectl export \
  --dsn "postgres://readonly:<PROD_READONLY_PASSWORD>@postgresql-saas.svc.plus:5432/account?sslmode=require" \
  --output /tmp/account-prod-snapshot.yaml
```

### 4.2 UAT 端增量合并演练 (Dry-Run Preview)
在导入 UAT 前，先执行 `--dry-run` 预览变动（不实际写入数据库）：
```bash
migratectl import \
  --dsn "postgres://account_user:<UAT_PG_PASSWORD>@postgresql-saas-uat.onwalk.net:5432/account" \
  --file /tmp/account-prod-snapshot.yaml \
  --regenerate-user-uuids \
  --dry-run \
  --merge \
  --merge-strategy timestamp
```

### 4.3 UAT 端正式增量合并 (Apply Import & Merge)
确认演练无误后，正式导入：
```bash
migratectl import \
  --dsn "postgres://account_user:<UAT_PG_PASSWORD>@postgresql-saas-uat.onwalk.net:5432/account" \
  --file /tmp/account-prod-snapshot.yaml \
  --regenerate-user-uuids \
  --merge \
  --merge-strategy timestamp
```

---

## 5. CI/CD 流水线集成与防呆脚本

### 5.1 防呆执行脚本
- 脚本位置: `platform-ops-toolkit/.github/scripts/data-migration/accounts_data_migration.sh`
- 功能:
  1. 接收 `MIGRATION_SOURCE_DSN` 和 `MIGRATION_TARGET_DSN`。
  2. 执行 DSN 方向断言校验（目标非 PROD、目标是 UAT、源与目标不同）。
  3. 执行 `migratectl export` -> `import --regenerate-user-uuids --dry-run` -> `import --regenerate-user-uuids --merge` -> **收敛校验**。
  4. 快照含口令哈希与 session token，用 `trap ... EXIT` 保证任何失败路径都会清除。
  5. 日志中的 DSN 口令一律脱敏。

### 5.2 第 4 步收敛校验（迁移是否真的生效）
`--merge` 之后，脚本用**同一份快照**再跑一次 `--dry-run`，断言三张表都是 `inserted=0`。
任何一张表还有 insert，说明 PROD 的行没有落到 UAT，脚本 `exit 1`。
这是防止「流水线绿了但数据没进去」的唯一自动化手段（`SKIP_VERIFY=true` 可跳过）。

### 5.3 GitHub Actions 集成
Workflow: `.github/workflows/data-migration.yaml`，job `accounts_data_migration`（`migration_scope=accounts`）。

| 输入 | 默认 | 说明 |
| :--- | :--- | :--- |
| `migration_scope` | `accounts` | `accounts` = 本文的 migratectl 账号迁移；`site` = 按站点域名驱动的整站迁移 |
| `accounts_dry_run` | `true` | 默认只做预览，绝不写目标库；正式合并须显式改为 `false` |
| `accounts_ref` | `main` | 构建 migratectl 的 accounts 仓库 ref |
| `vault_env_path` | — | 决定 Vault role 与 KV 路径，PROD→UAT 迁移选 `uat` |

Vault KV（**两个 DSN 都放在目标环境路径下**）：

```
kv/data/<env>/accounts-migration
  MIGRATION_SOURCE_DSN   postgres://readonly:<PW>@postgresql-saas.svc.plus:5432/account?sslmode=require
  MIGRATION_TARGET_DSN   postgres://account_user:<PW>@postgresql-saas-uat.onwalk.net:5432/account
```

把 PROD 侧凭据放在 UAT 路径下是有意为之：它是 `SELECT`-only 的 `readonly` 角色（防呆第 4 层），
这样单个环境作用域的 Vault role 就能完成迁移，**不需要**给它开 `kv/data/prod/*` 的读权限。
`data-migration_accounts_assert-credentials.sh` 会断言源 DSN 必须用 `readonly` 用户，
带写权限的 PROD 管理员凭据永远不会出现在这条流水线里。

> **前置条件**：Vault role 的 `job_workflow_ref` 白名单（`docs/tasks/vault_auth_split.sh` 的
> `ALLOWED_WORKFLOWS`）必须包含 `data-migration.yaml@*`，否则换不到 token，
> 报 `claim "job_workflow_ref" does not match any associated bound claim values`。
> 改完白名单需要由持有 Vault 管理 token 的人重跑一次 `vault_auth_split.sh` 才生效。

### 5.4 migratectl 必须一个二进制打两端
快照里的 `metadata.schemaHash` 取自**二进制自带的 `schema.sql`**（`sql/embed.go` 的 `Hash()`），
`import` 会校验它与自身的 hash 一致。所以 export 与 import 必须用**同一个** migratectl 二进制；
分别用 PROD/UAT 容器里各自版本的 migratectl 会直接报 `snapshot schema hash mismatch`。
CI 里由 `data-migration_accounts_build-migratectl.sh` 统一构建一次。

---

## 6. 验证与审计记录

### 6.1 自动化验证脚本
| 脚本 | 依赖 | 覆盖 |
| :--- | :--- | :--- |
| `.github/scripts/tests/accounts_data_migration_safeguard_test.sh` | 无（stub 掉 migratectl） | 防呆第 3 层的 10 条 DSN 断言 |
| `.github/scripts/tests/accounts_data_migration_e2e.sh` | docker + go | 两个一次性 PostgreSQL 容器跑完整第 4 章流程，31 条断言 |

```bash
# 防呆断言（秒级，CI 每次都跑）
.github/scripts/tests/accounts_data_migration_safeguard_test.sh

# 端到端（本地，需 docker）
ACCOUNTS_REPO=/path/to/ai-workspace-service/accounts \
  .github/scripts/tests/accounts_data_migration_e2e.sh
```

### 6.2 已验证项（2026-08-15，本地双容器演练，42/42 通过）
- [x] PROD 只读数据库 SQL `INSERT/UPDATE/DELETE` 全部 `permission denied`
- [x] `migratectl export` 可用只读 DSN 导出，快照为 `version: v1` 且带 `schemaHash`，文件权限 `0600`
- [x] `migratectl import --dry-run` 在事务内执行并回滚，UAT 三张表行数零变化
- [x] `--merge --merge-strategy timestamp` 正式导入，users/identities/sessions 全部落地
- [x] PROD `proxy_uuid` 原样保留，目标 `users.uuid` 重新分配且不再等于 `proxy_uuid`
- [x] 已存在旧 `users.uuid` 的目标用户在事务内完成 rekey，identities/sessions 及其他外键引用跟随新 UUID
- [x] 重放同一快照幂等，不产生重复行
- [x] 冲突时 `updated_at` 较新的 UAT 行被保留，报告中体现 `Conflicts skipped`
- [x] UAT 独有数据不被合并删除
- [x] 失败路径下快照被 `trap` 清除，日志中不出现明文口令

### 6.3 待真实环境验证
- [ ] PROD 只读 SSH 登录与写权限拦截测试（需 `create_readonly_ssh_user.yml` 已部署到 PROD web-saas 节点）
- [ ] runner 到 `postgresql-saas.svc.plus:5432` 与 `postgresql-saas-uat.onwalk.net:5432` 的网络可达性
      （公网不通则 `runner_type` 选 `self-hosted`）
- [ ] Vault `kv/data/uat/accounts-migration` 两个 DSN 键已写入
- [ ] `vault_auth_split.sh` 白名单更新后已重跑，`data-migration.yaml` 能换到 token
- [ ] 一次 `accounts_dry_run=true` 的真实流水线演练
- [ ] 一次 `accounts_dry_run=false` 的正式增量合并

---

## 7. 后续规划：按站点域名(domain)驱动的全量迁移

本文第 4 章是 **accounts 模块专用**的最小数据量迁移，是最核心的一条。与之并列的另一条路径是
`data-migration.yaml` 的 `migration_scope=site`——按站点域名驱动、与具体业务无关的整站迁移
（`make migrate DOMAIN=... → scripts/run_toolkit.py → Ansible playbooks`，域为
`ai-workspace` / `web-saas` / `infra-platform` / `agent-proxy`）。

两条路径的数据面完全不同，不应互相耦合：accounts 走 `migratectl` 的逻辑层增量合并，
site 走主机/容器/卷层面的整站搬迁。

**site 路径当前不可用**，接入前至少要修掉：

1. `Run Toolkit Action` 步骤的 `working-directory: platform-ops-toolkit` —— `actions/checkout`
   把仓库放在 workspace 根目录，这个子目录不存在，步骤必然失败。
2. `platform-ops_data_migration_run-toolkit-action-*.sh` 依赖的 `PROVISION_TOOLKIT_ACTION` /
   `PROVISION_TARGET_DOMAINS` / `PROVISION_SOURCE_HOST` / `PROVISION_*_DOMAIN_BASE` 六个变量，
   在 `data-migration.yaml` 里从未定义（它们来自 `platform-ops.yaml` 的 `provision` job 输出）。
   空值会让 `make migrate DOMAIN=` 作用到错误目标而不是报错。
3. `Download CMDB` 是 `continue-on-error: true`，artifact 缺失时 inventory 为空，
   Ansible 零主机命中仍 exit 0 —— 需要 `--list-hosts` 判 `hosts (0)` 的守卫。
