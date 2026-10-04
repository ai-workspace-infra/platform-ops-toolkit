# UAT 旧版升级与 Vault 清理：真实增量证据

核实日期：2026-10-04。本记录补充 #1239/#1240 合约与 fixture 结果，不是 PROD 放行记录。此前只凭代码推断的 Vault 字段，以本轮实际字段核实为准。

主线核实：#1239 已进入 main（ea754fcc67326dfc667a4c473bc01c3ffce78daf）；#1240 合并进原 stacked topic branch，并未进入 main。merged 状态不能替代 main 可达性证明，本增量不依赖 composite refactor。

## 真实 UAT 数据库

使用 `kv/uat/serverless/supabase` Session Pooler，只执行 SELECT，没有 DDL/DML、同步或密码修改。2026-10-04 14:32:55 Asia/Shanghai 的显式 `BEGIN READ ONLY` 复核确认 transaction_read_only=on；default_transaction_read_only=off，不能只依赖启动 PGOPTIONS。

| 项目 | 实际观测 |
| --- | --- |
| PostgreSQL | 17.6 |
| users / password 非空 | 23 / 20；未输出身份、密码或哈希 |
| identities | 5 |
| subscriptions | **0** |
| billing_plans | 11；目录非空不等于订阅非空 |
| schema_migrations | 1 行，version=2026092703，dirty=false |
| r3 Accounts 明确目标 | 2026092801，当前 DB 未达到 |

这些是当前数据诊断，不是旧版基线或实际升级保留证据。用户要求跳过 REVIEW_ACCOUNT_LOGIN_PASSWORD；本轮未使用它登录，也没有改用 bootstrap/root 凭据冒充授权旧 UAT 账号。

真实部署参考：[Serverless UAT run 37177058831](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37177058831)，tag `daily-build-2026.10.04-r3`；Accounts source `c2c343fe2c91bb31e7f7f9b4fa60512a66e2b4c9`，digest `sha256:4d69adfd3c71eced9ddf711bebed6a65e7ca1dca21bd572901c11cf3d02f0274`。该 run 中 digest 校验成功，不等于本轮独立核实当前 revision。

本轮 Accounts Cloud Run `/api/ping` HTTP 200，但 image/tag/commit/version 均为空，不能作为身份核验；一次 `/readyz` 请求超时，未据此单独认定业务故障。没有修改 GCP 认证或应用部署。

## 可复用只读诊断

新增的只读实现现归属 Playbooks 的 `scripts/data_operations/serverless/probe_uat_upgrade_readiness.py`：要求 UAT、与 PROJECT_REF 匹配的 Session Pooler 5432、postgres database、TLS 和明确 expected-version。凭据通过环境传递，不放入 psql argv；每条查询在显式只读事务中执行，错误不转发连接身份。Toolkit 不再保留该执行脚本及其 PostgreSQL 实现级测试。

检查用户/订阅计数、唯一且 clean 的版本记录和精确目标。缺表、空样本、多条/dirty 迁移记录、不完整迁移都有阻塞理由。工具始终标记三个业务 gates=blocked、eligible_for_prod=false，退出 1；结构符合也不能替代实际登录/权限/权益/额度/无重复扣款/迁移幂等。它不产生可放行的 upgrade_acceptance artifact，未改变部署工作流或迁移范围。

本工具于 14:39:38 Asia/Shanghai 实际连接上述 UAT，读到 users=23、identities=5、subscriptions=0、migration=2026092703/false、transaction_read_only=true；退出 1，报告空订阅、目标版本未达到及尚未执行的业务证据等阻塞项。它是本地真实只读运行，不是 GitHub 上的升级/登录验收 run。

本地通过 10 项 readiness 合约测试、13 项原业务门禁测试、工作流 gating 和脚本引用检查。新增 PostgreSQL 17 CI fixture 覆盖显式只读拒绝 UPDATE、空订阅、版本不足、dirty/多条/缺失版本表以及结构收敛仍不得晋级；该 fixture 只允许 localhost PostgreSQL 17 的独立临时数据库。

## Vault 实际字段与配置关系

完整 LIST 覆盖 51 个目录、95 个秘密路径，无目录访问失败。仅保留路径、字段名、版本和非空判断；敏感字段只在内存中比较，不导出内容或完整 DSN。

- `kv/uat/serverless/supabase`：PROJECT_REF、DATABASE_SESSION_POOLER_URL、DATABASE_DIRECT_URL、DATABASE_PASSWORD、DATABASE_USERNAME、DATABASE_NAME 六字段均非空；无 SUPABASE_CONNECT_URI、DATABASE_POOLER_URL。运行配置名需要追踪派生，不能直接补同名 KV。
- `kv/uat/databases`：account_database_uri/direct_uri 与上述 Session/Direct 的 host/port/database/user/password 一致；project ref/password 比较也一致。
- `kv/uat/accounts-migration`：三个迁移字段非空，但 MIGRATION_TARGET_DSN 与上述 Session Pooler 各连接维度不一致。不调用同步，不拼接不同后端的验收证据。
- `kv/uat/serverless/gcp`：仅 GCP_WORKLOAD_IDENTITY_PROVIDER、GCP_SERVICE_ACCOUNT_EMAIL；project/region 在当前部署由 GitOps 解析，不代表运行配置缺失。
- `kv/uat/billing-service`：STRIPE_SECRET_KEY、STRIPE_PUBLIC_KEY、SANDBOX_STRIPE_WEBHOOK_SECRET、SANDBOX_STRIPE_WEBHOOK_URL 非空；secret/public 测试前缀判断通过，但未核验 Stripe 账户身份。无 SANDBOX_STRIPE_SECRET_KEY、SANDBOX_STRIPE_XCONNECT_PAY_URL。
- `kv/CICD`：ROOT_BOOTSTRAP_PASSWORD 存在，ROOT_BOOTSTRAP_EMAIL 不存在；bootstrap 不是旧用户证据。
- `kv/CICD/uat`：SSH_PRIVATE_DEPLOY_KEY_B64 存在；未尝试 SSH，不能推定任何主机已授权。

## Vault 清理审计

扫描 76 个具有可解析提交的本地 Git 存储，使用本地 remote-default ref。本轮刷新 Toolkit、GitOps、Playbooks main，其他 refs 可能陈旧；未覆盖共享 checkout 修改。Hermes 没有可解析 HEAD，被排除。

机械分类：60 个明确代码/配置/策略引用、20 个模板引用、5 个仅文档/测试命中、10 个未命中。人工保留 10 个误判候选，最终 **90 个路径有保留理由，5 个待负责人确认，确认可安全删除为 0**。策略、注释、初始化脚本或命名空间引用不等于已证明当前运行消费每个 leaf。

`GET /v1/sys/audit` 成功，启用 audit device 为 **0**；无法通过本轮 Vault 历史访问记录证明停用。未擅自启用审计，创建/更新时间不是最后读取时间。

| 候选 | 当前版本 / 更新时间 UTC | 清理前必须核实 |
| --- | --- | --- |
| kv/console.svc.plus | v1 / 2026-03-09 | 旧账号的人工登录、旧 UAT、回滚用途 |
| kv/prod/XConnect/PH | v1 / 2026-09-09 | 旧父路径 SSH 字段；不能与仍被引用的子路径混淆 |
| kv/prod/accounts/oauth/google | v1 / 2026-09-07 | Google OAuth 功能仍存在，生产秘密来源与 enabled 配置 |
| kv/prod/gcp | v1 / 2026-08-31 | 与 serverless/gcp、platform/oidc、CICD bootstrap 的映射及外部消费 |
| kv/uat/ai-aggregator/gateway/kong | v2 / 2026-10-01 | 近期秘密及未提交 AI Aggregator 修改，确认 Kong 方案是否仍需保留 |

五个候选均仍可读且字段非空、未删除/销毁。本任务未执行 delete/destroy/metadata delete 或重构命名空间。

必须保留的误判案例：

- `prod/XConnect/PH/PH-XConnect.svc.plus` 被 GitOps enabled 节点的 mount-relative credentials_vault_path 引用；扫描不能只匹配 kv/ 前缀。
- UAT/PROD Accounts runtime pepper、UAT Caddy initializer、旧 UAT ulighthost-xconnect copy 输入都有构造式引用。
- Playbooks 读取分布式 VPN base_path + inventory_hostname；客户端 leaf 的独立读者未证明，整个命名空间保守保留。
- Accounts 共享 tenant 路径由 `xworkmate/tenants/%s/shared` 和固定共享 tenant ID 构造。
- 旧 Accounts 根路径混合 auth/OAuth/SMTP/bridge 字段，不能因跳过单个 review 字段而整体清理。

完整脱敏目录/字段/引用证据仅保留在本地 `.local-evidence`，不无差别上传全部 Vault 名称空间。负责人应逐项确认实际运行、人工流程、替代路径、保留期和回滚依赖；取得明确逐路径删除授权后才做可恢复操作。

## 三项硬门槛

| 门槛 | 状态 | 解除条件 |
| --- | --- | --- |
| 平滑升级 | BLOCKED | 授权旧 immutable baseline；正式 migration 达到 2026092801、重复幂等；数据关系、健康及 serving digest 证据 |
| 原用户登录 | BLOCKED | 其他授权既有 UAT 账号引用，实际原密码登录及有效权限验证；review 字段按要求跳过 |
| 原订阅保留 | BLOCKED | 授权旧版非空订阅；套餐/状态/有效期/权益、API/页面、额度及无重复扣款证据 |

当前不具备 PROD 晋级条件。不能升级后补样本来声称历史保留。若改为新建隔离旧版演练或给指定旧 UAT 用户补受控 Sandbox 样本，需负责人明确方案、账号和授权，不能自行猜测。PROD 源地址仍未确认，不执行生产数据同步或 DNS 变更。
