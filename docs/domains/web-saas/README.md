# Web SaaS 服务与入口域 (Domain: web-saas)

本域覆盖面向外部用户的 Web 控制台、静态分发、支付系统及流量加速代理入口。

## 1. 资产与组件清单

本域主要由无状态前端服务、分发平台及代理隧道节点构成：

### Web 服务与控制台 (核心入口)
- **Console**: `console.svc.plus` (127.0.0.1:3000) - Web Site Home Page Control Panel
  - **子路由 `/billing`**: 包含 Billing 计费流水、Payment Amount 等相关服务
  - **子路由 `/ebook`**: 包含在线文档、开源解决方案等静态分发 (`/opt/modern-it-history/current`)
- **Accounts**: `accounts.svc.plus` - 统一账户服务
- **Install Scripts**: `install.svc.plus` (302 Redir -> Github) - Short link distribution for curl-based one-click installation scripts

### 核心数据库层 (Database)
- **PostgreSQL**: `postgresql-saas.onwalk.net` - 承载 Web SaaS 业务的强状态独立数据库服务

### 加速 Pools (代理节点)
- **JP XHTTP / Xray**: `jp-xhttp.svc.plus` (跨越代理隧道 `/dev/shm/xray.sock`)
- **TKY Proxy**: `tky-proxy.svc.plus` (跨越代理隧道 `/dev/shm/xray.sock`)

## 2. 备份与同步策略

### 代理隧道与证书配置
- 导出底层的 Xray 路由与网关证书。由于本域大部分为前端入口与无状态转发层，重点在于确保底层证书 (`acme.json` 或 Caddy/Nginx 证书文件) 以及路由表的平滑迁移。
- 若包含 Xstream 和 Billing 相关的独立数据库，则需要使用 `pg_dump` 备份计费和支付状态信息。

### 静态文件同步
针对 Ebook 等挂载的静态数据，执行常规增量同步：
```bash
rsync -avz --delete /opt/modern-it-history/current/ backup-server:/opt/modern-it-history/current/
```

## 3. 恢复与上线流程
1. **静态数据还原**: 同步并恢复前端资源和挂载的静态卷。
2. **代理环境还原**: 在目标服务器配置相关的网络套接字（如 `/dev/shm/xray.sock`）。
3. **前端/网关重启**: 在 DNS 切换之前，确保对应的 Web 服务、Console 以及反代网关正确加载。DNS 切至新机器后，Caddy 会自动重新执行 HTTP 质询获取证书或加载迁移过的证书。

## 4. CI 部署前置 (`deploy_web_saas` job / Vault Secrets)

`.github/workflows/platform-ops.yaml` 里 `target_domains=web-saas`(或 `all`)
触发的 `deploy_web_saas` job，实际部署 postgresql.svc.plus / stunnel-client /
accounts.svc.plus / billing-service / console.svc.plus 这 5 个服务到同一台
provision 出来的主机上。

密钥来自两条路径。**web-saas 专属**密钥放在 `kv/data/WEB_SAAS`（人工维护，workflow 只读不写）：

| Key (`kv/data/WEB_SAAS`) | 说明 |
|---|---|
| `POSTGRES_ROOT_PASSWORD` | Postgres 容器的 root (`postgres`) 密码，首次 `initdb` 时写入；换密码要先手动改容器里的密码，再同步改这里，否则下次重跑对不上。 |
| `ACCOUNT_DB_PASSWORD` | `account` 库 `account_user` 账号的密码，由 `create_databases_and_users.yml` 建号时使用，也是 `accounts.svc.plus` 连库用的密码。 |
| `BILLING_DATABASE_URL` | billing-service 的完整 Postgres 连接串（`postgres://user:pass@stunnel-client:15432/db?sslmode=disable`），可以复用 `account_user`/`account`，也可以单独建一个账号。 |
| `INTERNAL_SERVICE_TOKEN` | billing-service 内部服务间鉴权 token。 |
| `EXPORTER_BASE_URL` | billing-service 的单源兼容入口，默认 `http://127.0.0.1:8080`。 |
| `EXPORTER_SOURCES_JSON` | billing-service 的主路径来源列表。当前 web-saas 先写单源 `xhttp-local`，后续可平滑扩成多源。 |

**公共服务**密钥放在共享的 `kv/data/CICD`（三个环境共读、只读不可改）：

| Key (`kv/data/CICD`) | 说明 |
|---|---|
| `GHCR_USERNAME` | 拉取 `ghcr.io/x-evor/*`、`ghcr.io/ai-workspace-services/*` 私有镜像用的 GHCR 用户名。 |
| `GHCR_TOKEN` | 对应的 GHCR token。workflow 里映射为 `GHCR_PASSWORD` 环境变量（脚本消费的是这个名字）。 |

**基础凭据**按环境拆分在 `kv/data/CICD/<env>`（各 role 只读自己那份）：

| Key (`kv/data/CICD/{sit,uat,prod}`) | 说明 |
|---|---|
| `SSH_PRIVATE_DEPLOY_KEY_B64` | ansible 连目标主机用的部署私钥。 |
| `VULTR_API_KEY` | provision 阶段创建主机用的云账号 API key。 |
| `TF_STATE_*` | Terraform state 后端的访问凭据。 |

workflow 里对应两个变量：`VAULT_KV`（公共服务）与 `VAULT_KV_BASE`（本环境基础凭据）。
分层理由与 KV v2 的路径匹配语义见
[vault_authentication_and_policy_isolation.md §2](../../vault/vault_authentication_and_policy_isolation.md)。

> GHCR 凭据曾经放在 `kv/data/WEB_SAAS`，现已统一到 `kv/data/CICD`——镜像拉取是
> 所有域共用的公共能力，没有按环境区分的意义。而 SSH 私钥、云账号 key 授予的是
> 登录主机和控制基础设施的能力，是提权的实际载体，因此按环境隔离。

这些 key 都需要提前在 Vault 里手动填好真实值。缺 web-saas 专属键时，
`Validate environment-scoped web-saas secrets` 这一步会在任何部署动作发生**之前**
直接 fail red（`vault-action` 开了 `ignoreNotFound`，键名写错只会拿到空值，
所以这道校验是必需的）。

### 必须的 Vault Policy (已在 [run #28732574921](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/28732574921/job/85200873591) 实测确认为阻塞项)

`Load Vault secrets` 这一步实测 `403 Forbidden`（整个 job 在读密钥这一步就失败，
后面所有部署 step 都不会执行）。

**根因**：`github-actions-platform-ops-toolkit` 这个 JWT role 初始化时
（见 [walkthrough.md §4](../../ZH/BackUP/Site-Migration/walkthrough.md)）**没有自己的
policy，借用的是 `token_policies: ["github-actions-xworkspace-console"]`**。而那个
policy（定义在 xworkspace-console 仓库
`docs/operations/vault-github-actions.md`）只覆盖 `kv/data/CICD` 和
`kv/data/openclaw` 两条路径，所以读新加的 `kv/data/WEB_SAAS` 必然 403。

**修复（推荐做法：给本仓库建独立 policy，不再蹭 xworkspace-console 的）**——
用管理员 token 在 `vault.svc.plus` 执行：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # 管理员 Token

# 1. 独立 policy：CICD 共享键(SSH/TF/Vultr) + web-saas 专属键
vault policy write github-actions-platform-ops-toolkit - <<'EOF'
path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["read", "list"]
}
path "kv/data/WEB_SAAS" {
  capabilities = ["read"]
}
path "kv/metadata/WEB_SAAS" {
  capabilities = ["read", "list"]
}
EOF

# 2. 把 role 的 token_policies 从借用的 xworkspace-console 切换到独立 policy
#    (其余 bound_claims 参数与 walkthrough.md 首次初始化保持一致)
vault write auth/jwt/role/github-actions-platform-ops-toolkit - <<'EOF'
{
  "role_type": "jwt",
  "user_claim": "repository",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "ai-workspace-infra/platform-ops-toolkit",
    "sub": "repo:ai-workspace-infra/platform-ops-toolkit:*"
  },
  "token_policies": ["github-actions-platform-ops-toolkit"],
  "token_ttl": "20m",
  "token_max_ttl": "30m"
}
EOF
```

> 备选做法是直接往共享的 `github-actions-xworkspace-console` policy 里追加
> WEB_SAAS 路径，改动更小，但会让 xworkspace-console 仓库的流水线也能读到
> web-saas 的数据库密码，不符合最小权限，不推荐。

操作完成后：

1. 打开 [kv/WEB_SAAS](https://vault.svc.plus/ui/vault/secrets/kv/list/WEB_SAAS/) 确认 6 个 key 都已填好真实值。
2. 直接重新触发 workflow 即可，role/policy 变更立即生效，无需其他操作。

在修复之前，`target_domains=web-saas`(或 `all`) 的 run 会在 `Load Vault secrets`
这一步就 403 失败，不会部署任何 web-saas 服务。

---

## 5. `deploy_web_saas` 部署链路

单机部署：5 个服务都跑在同一台 provision 出来的主机上。这个模式下，
`postgres` 只提供容器内 `5432`，`stunnel-server` 对外暴露 `15433`，
`stunnel-client` 则在应用侧提供 `15432` 的本地代理端口；如果需要跨节点访问，
就由 `stunnel-client -> stunnel-server -> postgres` 这条链路对外提供服务。
因此必须先补齐生产环境里各服务各自假设「已经存在」的共享前置条件——全新
主机上这些都不存在。

### 5.1 四个前置条件的落位

| 前置条件 | 落在哪一步 | 说明 |
|---|---|---|
| **Docker 引擎安装** | 步骤 12 `Bootstrap Docker + Caddy + shared network + stunnel certs` | 全新主机没有 docker，后面所有 compose 动作都依赖它。 |
| **`cn-toolkit-shared` Docker 网络** | 同上（步骤 12） | 各服务角色都假设该网络已存在，但**没有任何 playbook 会创建它**。bootstrap 里用 `docker network inspect` 探测后 `docker network create` 补建，因此**不需要独立的网络步骤**。 |
| **stunnel 自签证书** | 同上（步骤 12） | `postgresql_service` 角色在证书缺失时会直接 fail。由 `roles/host/stunnel-certs` 生成到 `/opt/cloud-neutral/stunnel-server/certs`。 |
| **`account` 库 / `account_user` 账号** | 步骤 19 `Provision account database and role` 建库建号<br>步骤 21 `Initialize account schema when absent` 灌基线 schema | 必须在 **Postgres 起来之后**。全新实例没有任何表，accounts 服务启动即 `relation users does not exist` 崩溃循环。 |

> 步骤 12 一步搞定前三件（docker / 网络 / 证书），所以链路里看不到独立的
> 「创建网络」或「生成证书」步骤。

### 5.2 完整链路（26 步中的部署主干）

```
Install Ansible
  → Build billing 二进制                    (runner 上 go build，不依赖外部产物)
  → Bootstrap (docker / cn-toolkit-shared 网络 / stunnel 证书)
  → 构建并灌入 postgres-extensions 镜像      (runner build → docker save | ssh docker load)
  → GHCR 登录                                (目标主机 docker login，后续私有镜像才拉得动)
  → Postgres
  → stunnel-client (仅跨节点模式需要)
  → 建 account 库 + 账号
  → 灌基线 schema
  → accounts → billing → console
  → Vault (co-located)
  → Monitoring (Vector / Node / Process)
```

几个非显性的依赖原因：

- **postgres-extensions 镜像必须自己构建**。`postgresql_service` 角色默认
  `postgresql_service_postgres_pull_image: false`，假设 `postgres-extensions:17`
  已在目标主机本地存在。它不是公开镜像，而是 postgresql.svc.plus 仓库里编译
  pgvector/pg_jieba/pgmq 的自定义镜像，从未发布到任何 registry——全新主机上
  `compose up` 会去 Docker Hub 拉 `postgres-extensions` 从而 404/403。
- **端口语义必须固定**。当前约定是：`postgres` 只监听容器内 `5432`，
  `stunnel-server` 对外占 `15433`，`stunnel-client` 对内占 `15432`。
  这样单节点和跨节点都走同一条服务语义链，但不会把数据库端口和 TLS 入口混在一起。
- **GHCR 登录必须早于 Postgres**。`stunnel-server` / `accounts` 等镜像是 GHCR
  私有包，全新主机没有登录态，隐式 pull 直接 unauthorized。
- **schema 只在 `users` 表不存在时灌一次**。`schema.sql` 是 drop+recreate 的基线，
  **绝不能在已有数据的库上重跑**。

### 5.3 为什么是按服务步骤，而不是单个 compose

`942e523 refactor(ci): compress platform-ops deployment steps` 曾把上述整条序列
压成单一的 monolithic compose 步骤，直接导致
[run #29884606925](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/29884606925)
**显示 ✓ success 但实际什么都没部署**：

- 该步骤设了 `working-directory: playbooks`，而 CMDB 产物下载在仓库根目录的
  `cmdb/`，于是 `-i cmdb/inventory.ini` 解析成不存在的 `playbooks/cmdb/inventory.ini`；
- **ansible ad-hoc 在 0 主机命中时返回 exit 0**，`set -e` 拦不住，4 条任务全部
  静默跳过，job 仍然是绿的。

同时那个 monolithic compose 文件本身也是残缺的：容器名与周边脚手架对不上
（`web-saas-postgres` vs 角色实际使用的 `postgresql`），并且 bind-mount 了 7 个
不在同步目录里的文件，其中 `stunnel-server.conf` / `stunnel-client.conf` 在整个
仓库里根本不存在。

因此链路已还原为按服务步骤。**任何时候都不要再把它压回单步**——每个服务的
前置条件、镜像来源、失败语义都不同，合并之后既无法定位失败，也会重新引入
「0 主机命中 = 绿」的假绿路径。

### 5.4 假绿防护

`common_assert_ansible_host.sh` 接在首个改机步骤（步骤 12 bootstrap）头部，
  断言目标主机在 inventory 中可解析且可达，0 主机命中时**直接 fail red**。
  一道断言保护整条序列。

### 5.5 两种数据库拓扑的切换约定

| 模式 | 连接路径 | 适用场景 | 需要的组件 |
|---|---|---|---|
| 单节点直连 | `compose -> postgres` | 同一台主机上的本机调试、脚本、备份验证 | `postgres` 即可 |
| 本机代理 | `compose -> stunnel-client -> postgres` | 应用侧统一走本地 15432 入口 | `postgres + stunnel-client` |
| 跨节点 TLS | `compose -> stunnel-client -> stunnel-server -> postgres` | 远程主机访问、跨宿主机业务服务连接 | `postgres + stunnel-server + stunnel-client` |

切换原则：

- `postgres` 只承担数据库存储，不再对宿主机额外发布端口
- `stunnel-server` 负责对外 TLS 入口，固定占用 `15433`
- `stunnel-client` 负责应用侧本地代理，固定占用 `15432`
- 业务容器默认继续走 `stunnel-client`，这样跨节点模式无需改业务配置
- 如果要做纯单节点验收，可以直接在同网段容器里连 `postgres:5432`，不必经过 stunnel-client

新增任何会改动主机的步骤时，若它使用 ansible ad-hoc（而非 `ansible-playbook`），
必须确认失败会被传播——ad-hoc 的 0 主机命中不会返回非零退出码。
