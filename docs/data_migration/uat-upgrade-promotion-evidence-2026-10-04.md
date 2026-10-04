# UAT 旧版升级验收与 PROD 晋级证据

核实时间：2026-10-04 13:13–13:16 Asia/Shanghai。本文记录已核实的配置、构件和阻塞；不是 PROD 放行记录。

后续增量核实见 [真实 UAT readiness 与 Vault 审计](uat-readiness-vault-audit-2026-10-04.md)：#1239/#1240 已合并，Vault 已完成只读遍历；真实 UAT 订阅为 0，migration 为 2026092703，三项业务门槛仍阻塞。下文保留早期核实范围，不能把早期凭据限制或推断字段当作最新结果。

## 交付边界与执行顺序

目标是证明已授权旧版 UAT 的原用户、原密码、权限、非空订阅及权益在真实升级后保留。顺序为：冻结旧版基线 → 受保护 checkpoint → 正式 migration → 应用升级 → 重复 migration → 登录/权限/订阅/额度/扣款验收 → 发布脱敏证据 → 晋级判定。

Toolkit 负责 Actions、Vault 引用、构件来源、验收判定；Accounts 负责正式 migration 和业务接口；Playbooks 负责主机上的 Ansible 配置与执行；GitOps 负责非秘密拓扑声明。Host 脚本的归属整理及 composite actions 使用独立 PR，不改变本次业务验收范围。不能清空或重新植入数据来冒充旧版保留测试，不能用 SQL 指纹替代实际登录，不能凭部署绿色或空样本放行。

当前正式 DB Init 是否应用完整 migration、是否幂等，必须另有真实执行证据。读取版本表和临时 PostgreSQL fixture 本身不能证明这两点。缺少 schema_migrations 必须阻塞或先执行经过审查且匹配旧版 schema 的基线认定；禁止直接 force 到目标版本。

## 当前可复核的证据

| 项目 | 证据及范围 |
| --- | --- |
| 已合并修复 | [Toolkit #1238](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1238)，main `399c8b7d05642de70468cd3dcb4d9c7a66e058ca`；SSH 预检及不依赖 DNS 的结构比对，不代表三项业务验收通过 |
| Selfhost 运行 | [37176728498](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37176728498)，控制面 `f9275dbc3277469eb485551ab20e19893c49a3cd`，早于 #1238；没有新的 baseline/acceptance jobs |
| Serverless 运行 | [37177058831](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37177058831)，成功且发布 serverless-artifact-manifest；仅部署成功不能证明旧版升级 |
| UAT 构件 | `daily-build-2026.10.04-r3`，下表来自该运行自己的 artifact |
| 公网只读检查 | Console `/login` HTTP 200；Accounts 公网 `/readyz` HTTP 404、`/api/ping` HTTP 401；Cloud Run Accounts `/readyz` HTTP 200。受保护 API 的 401 和 edge 未暴露的健康路由不能替代登录或据此判定业务不健康 |
| 本地云凭据 | gcloud 无法在非交互模式刷新凭据；Vault 本地认证不可用。没有读取或输出秘密值 |

| 服务 | Artifact Registry digest | Source commit |
| --- | --- | --- |
| accounts | `sha256:4d69adfd3c71eced9ddf711bebed6a65e7ca1dca21bd572901c11cf3d02f0274` | `c2c343fe2c91bb31e7f7f9b4fa60512a66e2b4c9` |
| billing-service | `sha256:84acdeaa7cbd49e321923b8ffbca351c564f0ce38a5b789a086319b4fc2f0d01` | `e241d3534a71a26f018260918f89d527d0e1f584` |
| content-service | `sha256:ee3939d3db8629f55b8da421d82dd5604c8973f3269bb6c344e8be7be66fdfb2` | `762089b736fb8a9336b617e892800e807d9dfa72` |

镜像仓库为 `asia-east1-docker.pkg.dev/open-platform-uat/serverless/<service>`。以上是工作流发布的构件身份；独立读取当前 serving revision/digest 尚受本地 GCP 认证阻塞，不能称为本轮独立线上 digest 核验。

Accounts 该 source commit 的 .up.sql 最大版本为 **2026092801**。新增解析器要求 checkout commit 对应部署 tag，并从该构件的 sql/migrations 推导明确目标；实际数据库必须恰好达到目标且 dirty=false。版本不低于升级前不足以通过。

## 环境与 Vault 配置来源

GitOps 最新远端 main 为 `96de9a2`；实际执行需固定完整 commit。配置来源为 `topology/uat/hybrid/resource-matrix.json`、`topology/uat/serverless/runtime-topology.yaml`、`compose/web-saas/docker-compose.yml`，以及所选 profile 对应的 resources。资源矩阵声明 web-saas 使用 gcp-cloud、asia-east1、terraform+serverless；不能使用旧文档的固定 VPS 源地址推定当前部署。

- Console：`console-serverless-uat.onwalk.net`，Frontend Router / SSR Workers / Pages。
- Accounts：`accounts-serverless-uat.onwalk.net`，Edge Gateway / Cloud Run。
- Billing：最新拓扑为 `billing-uat.onwalk.net`，与旧文档的 mode-qualified 域名有差异。
- Pages：`ai-workspace-portal-uat`。
- Cloud Run 上游：`uat-accounts-4ueoyqlpbq-de.a.run.app`、`uat-billing-service-4ueoyqlpbq-de.a.run.app`、`uat-content-service-4ueoyqlpbq-de.a.run.app`。
- Selfhost 与 Serverless 数据库分别核实；必须证明验收 API、migration 与样本属于同一数据集，不能跨后端拼接通过证据。
- `dns_mode=none` 时仍需执行验收；本任务不修改生产 DNS，不重新同步未知生产源。

Vault 地址由 VAULT_ADDR 注入；仓库默认 https://vault.svc.plus。Actions 使用 GitHub OIDC、audience=vault、role=github-actions-platform-ops-toolkit-uat。实际 mount、role 绑定、白名单、KV 版本、字段存在性及运行时消费关系还需凭已授权认证核实。

以下是代码中的 KV v2 API 引用，不代表本轮已经读取到这些字段。CLI 路径去掉 /data/。

| KV v2 路径 | 相关字段/用途 |
| --- | --- |
| kv/data/uat/serverless/supabase | PROJECT_REF、DATABASE_SESSION_POOLER_URL、DATABASE_DIRECT_URL、SUPABASE_CONNECT_URI、DATABASE_POOLER_URL、DATABASE_PASSWORD、DATABASE_USERNAME、DATABASE_NAME |
| kv/data/uat/serverless/gcp | GCP_PROJECT_ID、GCP_REGION、GCP_WORKLOAD_IDENTITY_PROVIDER、GCP_SERVICE_ACCOUNT_EMAIL |
| kv/data/uat/serverless/cloudflare | CLOUDFLARE_ACCOUNT_ID、CLOUDFLARE_API_TOKEN |
| kv/data/WEB_SAAS | INTERNAL_SERVICE_TOKEN、AUTH_TOKEN_PUBLIC_TOKEN、AUTH_TOKEN_REFRESH_SECRET、AUTH_TOKEN_ACCESS_SECRET；现有共享路径应记录实际消费，不能在本任务顺带重构 |
| kv/data/CICD | ROOT_BOOTSTRAP_EMAIL、ROOT_BOOTSTRAP_PASSWORD；不得把 bootstrap 凭据当作旧用户样本，须确认升级启动不会重置其密码或权限 |
| kv/data/uat/accounts/oauth/github | client_secret；非秘密 client ID/redirect/frontend 配置来自 GitOps |
| kv/data/uat/billing-service | SANDBOX_STRIPE_SECRET_KEY、SANDBOX_STRIPE_WEBHOOK_SECRET、SANDBOX_STRIPE_XCONNECT_PAY_URL；脚本存在无前缀回退，核实实际 Sandbox 身份 |
| kv/data/CICD/uat | SSH_PRIVATE_DEPLOY_KEY_B64；部署 SSH，不等同于生产源同步授权 |
| kv/data/uat/databases | postgres_root_password、account_pg_password、billing_pg_password 等；Selfhost 实际 Accounts/Billing 共享 account/account_user，核实最终注入来源 |
| kv/data/uat/accounts-migration | MIGRATION_SOURCE_DSN、MIGRATION_TARGET_DSN、MIGRATION_SOURCE_SSH_PRIVATE_KEY_B64；本任务暂不调用真实同步 |
| kv/data/uat/serverless/database-backup | BACKUP_ENCRYPTION_PASS |
| kv/data/CICD/uat/iac_state | TF_STATE_BUCKET、TF_STATE_ACCESS_KEY、TF_STATE_SECRET_KEY、TF_STATE_REGION、TF_STATE_ENDPOINT；持久化 checkpoint |

Supabase migration 默认使用 DATABASE_SESSION_POOLER_URL（Session Pooler 5432）；Direct 分支使用 DATABASE_DIRECT_URL。验证 project ref、脱敏 host/port/database/role、TLS、权限和网络；不使用 Transaction Pooler 6543 执行 migration。Cloud Run 注入 SUPABASE_CONNECT_URI，不能套用旧 VPS 的 DATABASE_URL/stunnel 合约。

秘密、完整 DSN、密码哈希、会话和指纹均不得进入公开 artifact 或日志。比较秘密只报告结果；低熵字段不能公开普通哈希。

## 晋级证据合约与当前门槛

`verify-promotion-manifest.py` 要求 accepted artifact 的 upgrade_acceptance 记录覆盖同一 snapshot tag 和所有待晋级镜像 digest，并包含不同旧版 immutable tag、非空旧用户/订阅计数、明确 migration 目标/实际版本、dirty=false。三项 gates 都必须 passed、每项执行检查为 true，并有本仓库 UAT run/job URL。完整业务记录参与与可信运行 artifact 的来源比较；调用者不能用 flags 或修改 JSON 替代真实执行。记录缺失、任一 skipped/failed/blocked 均拒绝晋级。Synthetic 测试 fixture 不得作为运行时证据。

当前没有实际执行三项门槛的证据生产器，也不生成伪造的 passed 记录。Selfhost 检查在 SQL/image/health 可通过时仍明确阻塞未执行的业务检查；这是暂时且有意的失败关闭状态，不能把此 PR 描述为完整登录验收已实现。

| 硬门槛 | 当前状态 | 缺少的证据 |
| --- | --- | --- |
| 平滑升级 | **阻塞** | 授权旧版基线及部署前构件身份、完整正式 migration/重复执行、实际 DB 精确版本及 serving digest |
| 原用户登录 | **阻塞** | 受保护的既有 UAT 账号凭据引用；实际登录、原密码兼容、有效权限允许/拒绝检查 |
| 原订阅保留 | **阻塞** | 同一既有用户的非空订阅；套餐/状态/有效期/权益比对；API/页面可读、额度不重置、无重复扣款证据 |

下一步需要旧版样本所属后端及已有 Vault KV 路径/字段名，不能在聊天提供秘密值。无此信息时继续独立代码检查与只读诊断；不复制生产密码/支付数据，不猜生产 SSH 地址，不晋级 PROD。
