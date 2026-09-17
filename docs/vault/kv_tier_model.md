# Vault KV 三层模型（规范）

本文是 `kv/` 布局的**规范定义**：新增任何一个 secret 之前，先照这里判断它属于哪一层。

现状盘点与具体迁移待办见 [kv_layout_and_migration.md](./kv_layout_and_migration.md)；
role 绑定与 policy 生成见 [vault_authentication_and_policy_isolation.md](./vault_authentication_and_policy_isolation.md)。

---

## 1. 分层表

| 层 | 路径 | sit | uat | prod | 权限 |
|---|---|---|---|---|---|
| **① 公共服务** | `kv/data/CICD`（GHCR）、`kv/data/openclaw`、`kv/data/action-runner` | ✅ | ✅ | ✅ | **只读，不可改** |
| **② 基础凭据** | `kv/data/CICD/<env>` + `kv/data/CICD/<env>/iac_state` | 仅 `sit` | 仅 `uat` | 仅 `prod` | **只读** |
| **③ 环境业务密钥** | `kv/data/<env>/*` | 仅 `sit` | 仅 `uat` | 仅 `prod` | 可读写（prod 无 `delete`） |

## 2. 归属判据

按顺序问三个问题，第一个答「是」的就是它的层：

1. **它授予「控制基础设施」或「登录主机」的能力吗？**
   → **② 基础凭据**。云账号 API key、Terraform state 后端凭据、SSH 部署私钥、
   （待定）DNS API token 都属于这一层。这是提权的实际载体，必须按环境隔离：
   sit 失陷不应拿到 prod 的云账号与主机私钥。

2. **换个环境它的值会变吗？**
   → 会变则 **③ 环境业务密钥**；不会变则 **① 公共服务**。

3. 其余情况按 ③ 处理。**默认隔离，共享要有理由**——把一个 secret 放进 ① 需要能说清
   「为什么三个环境用同一份是对的」，而不是「反正现在只有一份」。

### 典型判例

| Secret | 层 | 理由 |
|---|---|---|
| `GHCR_USERNAME` / `GHCR_TOKEN` | ① | 三个环境拉的是同一批镜像，不存在环境维度。 |
| `VULTR_API_KEY` | ② | 能创建/销毁任意主机。 |
| `TF_STATE_*` | ② `iac_state` | 通过环境级 S3-compatible backend 访问对应 state 前缀。 |
| `SSH_PRIVATE_DEPLOY_KEY_B64` | ② | 能登录目标主机。 |
| `POSTGRES_ROOT_PASSWORD` | ③ | 每个环境自己的数据库。 |
| `xray_uuid` | ③ | 已在 `kv/<env>/agent-proxy`，正确。 |

## 3. 不变式

分层不是文档约定，是**可执行的断言**。以下 7 条由
[`scripts/vault/vault_layout_verify.py`](../../scripts/vault/vault_layout_verify.py) 校验：

1. 三个 role 都能读 ① 的全部路径。
2. ① 的路径上**没有任何** `create` / `update` / `delete` / `patch` / `sudo`——
   公共资产不允许被任何单一环境的流水线改动。
3. 每个 role 能读**自己**的 `kv/data/CICD/<env>` 与 `kv/data/CICD/<env>/iac_state`。
4. ② 的路径同样只读。流水线**消费**凭据，不负责**轮换**凭据。
5. 每个 role 的 policy 里**不出现**其他环境的 `kv/data/CICD/<other>`。
6. **不使用 `kv/data/CICD/*` 通配符**——它会一次性击穿第 5 条。
7. prod 在 `kv/data/prod/*` 与 `kv/metadata/prod/*` 上都没有 `delete`。
   （`kv/metadata` 的 `delete` 会**永久销毁一个 secret 的全部版本**，比 `kv/data` 的软删危险得多。）

```bash
./scripts/vault/vault_layout_verify.py    # 退出码 0 = 全过, 1 = 有失败, 可做 CI 门禁
```

### 为什么 ①② 能同时成立

`kv/data/CICD` 与 `kv/data/CICD/<env>` 在 KV v2 里是**两个独立的 secret**——一个路径
既可以是 secret 本身、也可以是子路径的前缀。而 policy 里 `path "kv/data/CICD"`
**只精确匹配根路径，不匹配子路径**（要匹配子路径必须写成 `kv/data/CICD/*`）。

所以「共读根路径 + 只读自己那份子路径」是严格成立的，不需要改名或换挂载。
第 6 条不变式正是守住这个前提。

---

## 4. 脚本

| 脚本 | 作用 | 是否写 Vault |
|---|---|---|
| [`scripts/backup/vault_backup_to_keychain.sh`](../../scripts/backup/vault_backup_to_keychain.sh) | 全量导出 → macOS Keychain，回读比对 sha256 | 否（只读） |
| [`scripts/vault/vault_layout_verify.py`](../../scripts/vault/vault_layout_verify.py) | 校验上面 7 条不变式 | 否（只读） |
| [`scripts/vault/vault_migrate_base_credentials.sh`](../../scripts/vault/vault_migrate_base_credentials.sh) | 迁移第 1 步：provider/主机凭据 → `kv/CICD/<env>`，state 凭据 → `kv/CICD/<env>/iac_state` | 是（只新增，不删除） |
| [`docs/tasks/vault_auth_split.sh`](../tasks/vault_auth_split.sh) | 生成 policy 与 jwt role | 是 |

### 执行顺序

```bash
# 0. 先备份 —— 后面每一步都改 Vault
./scripts/backup/vault_backup_to_keychain.sh

# 1. 基础凭据落到各环境路径 (先看要做什么)
./scripts/vault/vault_migrate_base_credentials.sh --dry-run
./scripts/vault/vault_migrate_base_credentials.sh

# 2. 应用 policy 与 role
./docs/tasks/vault_auth_split.sh

# 3. 校验分层不变式
./scripts/vault/vault_layout_verify.py
```

迁移脚本的两个安全属性值得单独说明：

- **不覆盖。** 目标路径已存在的键默认跳过。这样当你后续把某个环境换成**独立凭据**
  之后，重跑脚本不会把它清回共享的那一份。要强制覆盖用 `--force`。
- **不删除。** 从根路径移除已搬走的键是迁移的最后一步，风险等级完全不同
  （见 [kv_layout_and_migration.md §2.2](./kv_layout_and_migration.md)：还有 4 个
  workflow 在从根路径读），因此不放在本脚本里。

---

## 5. 现在还不成立的部分

分层描述的是**目标状态**。以下几点尚未达成，不要按已完成来假设：

- **`kv/CICD/{sit,uat,prod}` 及其 `iac_state` 子路径尚未创建**，凭据还在根路径上。
- **`prod/` 不存在**，第 ③ 层在 prod 上是空的。
- **三个环境仍共用同一份凭据**。第 1 步脚本跑完只是把同一份复制成三份——
  **路径已隔离，凭据仍复用**。真正的隔离收益要等各环境换成独立的
  Vultr key 与 SSH 密钥对之后才成立。在那之前，②「按环境隔离」只是结构就位、
  安全效果尚未兑现。
- **`kv/data/WEB_SAAS`** 仍由 uat 与 prod 共读，两个环境共用同一套数据库口令。
  它属于第 ③ 层，应迁往 `kv/data/<env>/web-saas`。
