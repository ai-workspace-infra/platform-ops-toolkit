# GitOps 数据迁移拓扑与流水线触发机制优化方案 (Implementation Plan)

## 1. 架构目标与背景

随着平台数据库逐步由传统单机 VPS PostgreSQL 演进为云原生 Serverless 架构（Supabase Cloud DB），现有基于 VPS 容器 SSH 隧道的迁移链路已无法满足纯云上数据库之间的同步需求。

本方案旨在：
1. **解耦“策略声明（GitOps）”与“流水线执行（Toolkit）”**：通过在 GitOps 仓库的 Runtime Topology 中声明数据拓扑与交付模式，使流水线成为纯粹的声明式执行引擎；
2. **在 `data-migration.yaml` 中补充 `PROD Supabase -> UAT Supabase` 模式**：摆脱对 VPS 宿主机网络与 SSH Deploy Key 的依赖，利用 Runner 原生 TLS 直连执行 `migratectl export` + `migratectl import --merge`；
3. **优化日常构建快照派发机制 (`daily-main-snapshot.yaml`)**：
   - **UAT 流水线**：默认触发数据迁移，执行从 PROD Supabase 到 UAT Supabase 的单向增量同步；
   - **PROD 流水线**：以 `upgrade`（应用升级）为主，默认严禁触发数据迁移；迁移需显式定义与授权，防止误操作。

---

## 2. 四种数据迁移模式的统一抽象

在 `.github/workflows/data-migration.yaml` 中，通过 `accounts_source_backend` 与 `accounts_target_backend` 参数将迁移能力标准化：

| 迁移模式 | `accounts_source_backend` | `accounts_target_backend` | 通信通道 | 机制与凭据模型 |
| :--- | :--- | :--- | :--- | :--- |
| **① VPS → VPS** | `vps` | `vps` | SSH / direct DSN | 传统双机 PostgreSQL 迁移，使用 Host SSH Key 与两端 DSN |
| **② PROD VPS → UAT Supabase** | `vps` | `supabase` | SSH 连入 PROD 容器 | `pg_dump` 导出 public schema，流回 Runner 写入 Supabase |
| **③ PROD Console → UAT Supabase** | `vps` | `supabase` | SSH 连入 PROD 容器 | 容器内 `migratectl export`，Runner `migratectl import --merge` |
| **④ PROD Supabase → UAT Supabase** *(新增)* | `supabase` | `supabase` | **Runner 双向 TLS 直连** | Runner 直连 PROD Supabase 只读 DSN 执行 `export`，直连 UAT Supabase 执行 `import --merge` |

---

## 3. 安全规范与断路防呆 (Circuit Breaker)

1. **单环境只读凭据隔离**：
   - PROD Supabase 只读用户（仅具 `SELECT` 权限）连接串统一存放于 UAT 作用域的 Vault：
     ```text
     kv/data/uat/accounts-migration
       MIGRATION_SOURCE_DSN = postgres://readonly:<PW>@aws-0-<region>.pooler.supabase.com:5432/postgres?sslmode=require
     ```
   - UAT Runner 使用 `github-actions-platform-ops-toolkit-uat` 凭据即可闭环读取，绝不给 UAT 授予跨环境读写 `kv/data/prod/*` 的权限。
2. **强制断言**：
   - 源端 DSN 必须带有 `readonly` 或只读项目特征；
   - 目标端 DSN 必须与 UAT Supabase `PROJECT_REF` 一致；
   - 源 DSN 与目标 DSN 绝对禁止相同；
   - 目标端绝对禁止指向 `svc.plus` 生产域或 PROD Supabase 实例。

---

## 4. GitOps 声明规范

在 GitOps 仓库 `topology/<env>/serverless/runtime-topology.yaml` 中，将交付模式与迁移策略提升为一级声明：

### 4.1 UAT 拓扑示例 (`topology/uat/serverless/runtime-topology.yaml`)
```yaml
spec:
  runtime:
    mode: serverless
  delivery:
    default_operation: deploy+migrate
  data:
    primary: serverless
    providers:
      serverless: supabase
    migration:
      strategy: accounts_merge
      source:
        provider: supabase
        env: prod
        connection_mode: session_pooler
      target:
        provider: supabase
        env: uat
        strategy: accounts_merge
        confirm_replace: false
```

### 4.2 PROD 拓扑示例 (`topology/prod/serverless/runtime-topology.yaml`)
```yaml
spec:
  runtime:
    mode: serverless
  delivery:
    default_operation: upgrade
  data:
    primary: serverless
    providers:
      serverless: supabase
    migration:
      auto_trigger: false
      allowed_operations:
        - upgrade
```

---

## 5. 详细实现计划与变更清单

### 5.1 迁移执行引擎改造
* **`.github/workflows/data-migration.yaml`**:
  - 新增 `accounts_source_backend` 输入（`vps` | `supabase`，默认 `supabase`）；
  - 当 `accounts_source_backend == 'supabase'` 时，从 Vault 加载 `MIGRATION_SOURCE_DSN`，跳过 SSH 隧道配置，直接触发 `supabase_accounts_merge_migration`。
* **`.github/scripts/data-migration/supabase_accounts_merge_migration.sh`**:
  - 新增 `SOURCE_BACKEND` 逻辑分支；
  - 若为 `supabase`，直接在 Runner 执行：
    ```bash
    "${MIGRATECTL_BIN}" export --dsn "${SOURCE_DSN}" --output "${SNAPSHOT_FILE}"
    ```
    随后继续使用现有的 `--merge --merge-strategy timestamp` 导入目标端。
* **`.github/scripts/data-migration/validate_accounts_migration_target.sh`**:
  - 增加对 `source=supabase, target=supabase` 模式的校验与安全断言。

### 5.2 编排与派发层微调
* **`.github/workflows/serverless-orchestrator.yml`**:
  - 在 `operation` 选项中补充 `upgrade`：
    `options: [plan, init-schema, deploy, upgrade, migrate, deploy+migrate, destroy]`；
  - 应用部署任务统一兼容 `upgrade`（不执行数据迁移）。
* **`.github/scripts/snapshots/dispatch-uat-combined.sh`**:
  - 调整 serverless 派发参数为 `-f operation=deploy+migrate`；
  - 传入 `accounts_source_backend=supabase`。
* **`.github/scripts/snapshots/dispatch-prod-combined.sh`**:
  - 调整 serverless 派发参数为 `-f operation=upgrade`；
  - 严格禁用无确认的自动化数据迁移。
* **`.github/workflows/daily-main-snapshot.yaml`**:
  - 补充 `enable_migration` 参数（UAT 默认为 true，PROD 默认为 false），提供清晰的控制界面。

### 5.3 契约测试与验证
* **`.github/scripts/tests/data_migration_mode_contract_test.sh`**: 补充双端 Supabase 校验测试；
* **`.github/scripts/tests/serverless_dispatch_contract_test.sh`**: 补充 `upgrade` 选项测试；
* **`.github/scripts/tests/daily_snapshot_combined_dispatch_test.sh`**: 覆盖最新的 UAT 与 PROD 派发行为断言。
