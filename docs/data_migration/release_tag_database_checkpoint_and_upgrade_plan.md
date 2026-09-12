# 架构规划：基于 Release Tag 的数据库原子化升级与备份回滚体系 (Supabase & VPS PostgreSQL)

> **核心目标**：实现生产每次发布的**原子化升级（Atomic Upgrades）**与**确定性可回滚（Deterministic Rollback）**。任何一次发布在发生异常时，均能在秒级到分钟级安全回退至上一稳定版本 Release Tag，彻底杜绝代码回退但数据库被破坏的非一致状态。

---

## 1. 三维原子化模型 (Three-Dimensional Atomicity)

为了保障升级过程具备严格的事务性（All-or-Nothing），我们在架构上将发布流程解构为三个维度的原子保障：

```
                    [Production Release Trigger (vYYYY.MM.DD)]
                                       │
            ┌──────────────────────────┴──────────────────────────┐
            ▼                                                     ▼
┌───────────────────────┐                             ┌───────────────────────┐
│  1. Compute/Traffic   │                             │  2. Database Layer    │
│     (Blue/Green)      │                             │  (Expand-Contract)    │
├───────────────────────┤                             ├───────────────────────┤
│ • Cloud Run Revision  │                             │ • Tag-Bound Snapshot  │
│ • Cloudflare Worker   │                             │ • Non-breaking DDL    │
│ • VPS Local Container │                             │ • In-DB Ledger Audit  │
└───────────┬───────────┘                             └───────────┬───────────┘
            │                                                     │
            └──────────────────────────┬──────────────────────────┘
                                       ▼
                       ┌───────────────────────────────┐
                       │  3. Orchestrator Health Gate  │
                       │     (Atomic Commit / Abort)   │
                       └───────────────┬───────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    ▼ Success                             ▼ Failure (Any step)
         [Promote Traffic 100%]                [Auto-Rollback to v_prev]
         [Mark Ledger 'success']               [Zero-Downtime Traffic Revert]
                                               [Optional DB Snapshot Restore]
```

### 1.1 应用与流量原子化 (Compute/Traffic Layer)
- **Cloud Run**：采用 Revision 机制。新镜像部署时流量分配为 0%，待健康检查（`/healthz`）通过后原子切换流量至 100%；发生异常时秒级切回上一稳定 Revision。
- **Cloudflare SSR / Pages**：Worker 脚本基于 immutable tag 部署，切流由边缘路由原子切换。
- **VPS 容器集群**：采用预拉取（Pre-pull）与热备健康探针，在 Caddy 层完成秒级平滑切流。

### 1.2 数据库向后兼容设计 (Expand-Contract 模式)
- **拒绝单次破坏性 DDL**：在同一次发布中严禁同时“删除列/重命名列”与“应用切流”。
- **Expand（展开阶段）**：所有 DDL 必须对旧版本代码向后兼容（新增列允许 NULL 或提供默认值）。即便应用因异常回滚至 `v_{prev}`，旧代码仍然能正常读写数据库。
- **Contract（收缩阶段）**：在业务平稳运行且上一个版本已彻底下线后，再执行废弃列清理。

### 1.3 流程原子门禁 (All-or-Nothing Pipeline Gate)
- 全流程推进链条：
  $$\text{Pre-flight} \longrightarrow \text{Database Checkpoint} \longrightarrow \text{Compute Stage} \longrightarrow \text{Smoke Verification} \longrightarrow \text{Traffic Cutover}$$
- 链条上任意一步失败，流水线立即中断并激活回滚机制。

---

## 2. 异构数据库升级与备份点设计对比

| 关键维度 | Supabase Cloud (托管云端) | VPS PostgreSQL (自建容器) |
| :--- | :--- | :--- |
| **网络通路** | Session Pooler (端口 5432) TLS 直连 | Docker 容器间通信 (`docker exec`) |
| **备份提取范围** | 纯业务 Schema (`--schema=public`) | 业务库 (`account`, `billing`) + `globals` |
| **平台托管安全** | 严格排除 `auth`, `storage`, `vault` 等系统 Schema | 完整备份角色权限与各独立库 |
| **本地热备池** | 保留最新一次预发布快照于执行机/Runner | 宿主机保留最近 5 个 Tag (`/var/backups/checkpoints/${tag}/`) |
| **异地冷备池** | AES-256 加密推送到 R2/S3 (保留 90 天) | AES-256 加密推送到 R2/S3 (保留 90 天) |
| **导出耗时** | ~ 8 秒 (1.8 MB 实测) | ~ 3 秒 (本地直接导出) |
| **回滚 RTO** | < 3 分钟 (重置 public 并还原) | < 30 秒 (宿主机本地秒级 `psql` 重放) |

### 2.1 统一库内版本账本 (`system_release_checkpoints`)
在两类数据库中常驻统一审计账本表，记录版本演进轨迹：

```sql
CREATE TABLE IF NOT EXISTS public.system_release_checkpoints (
    id BIGSERIAL PRIMARY KEY,
    release_tag VARCHAR(64) NOT NULL,            -- e.g. v2026.09.12-r1
    environment VARCHAR(32) NOT NULL,            -- prod, uat, sit
    database_backend VARCHAR(32) NOT NULL,       -- supabase, vps
    database_name VARCHAR(64) NOT NULL,          -- account, postgres
    git_sha VARCHAR(40) NOT NULL,                -- 代码 Git Commit
    backup_s3_uri TEXT NOT NULL,                 -- s3://.../v2026.09.12.sql.gz.enc
    local_backup_path TEXT,                      -- VPS 本地热备路径
    schema_hash VARCHAR(64),                     -- 迁移结构哈希
    status VARCHAR(32) NOT NULL,                 -- 'checkpointed', 'upgraded', 'rolled_back'
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_release_checkpoints_unique 
    ON public.system_release_checkpoints (release_tag, environment, database_backend, database_name);
```

---

## 3. 双级回滚矩阵 (Two-Tier Rollback Matrix)

```
[生产发布发生异常 / 告警触发]
             │
             ▼
   [Schema 是否损坏或数据受污染?]
     ├── 否 (常规应用缺陷 / 性能抖动) ──> 【Tier 1: 软回滚 (秒级零停机)】
     │                                    • Cloud Run 回拨至上一稳定 Revision
     │                                    • Cloudflare / Caddy 流量切回旧 Tag
     │                                    • 数据库保持现状（兼容读写）
     │                                    • RTO < 30 秒，业务无感知
     │
     └── 是 (不可逆 DDL 报错 / 数据污染) ──> 【Tier 2: 硬回滚 (分钟级原子还原)】
                                          • 启用边缘维护页面排空写入
                                          • Supabase / VPS 从当前 Tag Checkpoint 恢复
                                          • 应用版本同步切回旧 Tag
                                          • 解除维护模式
                                          • RTO < 3 分钟，保证数据精准归位
```

---

## 4. 实施推进计划

1. **Phase 1: Checkpoint 自动化引擎与账本初始化**
   - 编写 `scripts/database/release_checkpoint.sh`，实现 Supabase TLS 与 VPS Docker 的统一导出、加密、校验与账本登记；
   - 编写 `scripts/database/restore_release_checkpoint.sh`，实现根据 Release Tag 自动拉取本地或云端快照的恢复逻辑。
2. **Phase 2: CI/CD 升级门禁接入**
   - 在 `serverless-orchestrator.yml` 和 `selfhost-orchestrator.yml` 中挂载 `database_checkpoint` 门禁任务；
   - 确保当且仅当 Checkpoint 验证通过后，方可推进无状态微服务部署。
3. **Phase 3: 一键回滚工作流搭建**
   - 新建 `.github/workflows/rollback-orchestrator.yml`，支持通过参数一键执行 Tier 1 软回滚与 Tier 2 硬回滚。
4. **Phase 4: UAT 全流程演练与验收**
   - 在 UAT 环境模拟升级并触发异常，全链路验证秒级切流与分钟级数据恢复。
