# 统一数据库备份与灾备方案 (PostgreSQL)

本文档基于 `install.svc.plus` 线上环境的实际部署情况，为你规划和整理了全局 PostgreSQL 数据库的备份、还原与灾备（DR）标准操作流程。

## 1. 线上环境数据库架构清单

| 实例用途 | 运行模式 | 监听端口/地址 | 包含的业务系统库 |
| :--- | :--- | :--- | :--- |
| **核心 AI/IAM/代码 全局库** | Docker (`postgresql-svc-plus`) | `127.0.0.1:5432` | Account, LiteLLM, Knowledge DB (RAG), Zitadel IAM, Gitea Code |

## 2. 统一备份策略 (Backup)

为了实现无缝灾备，建议采用 **逻辑备份 (Logical Backup)** 结合 **定时异地转储 (Offsite Sync)** 的策略。

### 2.1 编写全局备份脚本

在宿主机 (`install.svc.plus`) 的 `/opt/backup/` 目录下创建统一备份脚本 `pg_backup.sh`：

```bash
#!/bin/bash
# ==========================================
# 统一 PostgreSQL 备份脚本
# ==========================================
BACKUP_DIR="/var/backups/postgresql"
DATE=$(date +"%Y%m%d_%H%M%S")
mkdir -p $BACKUP_DIR

echo "[INFO] 开始备份所有业务库 (15432 端口)..."
DB_URL_BASE="postgres://svcplus_vps:<YOUR_PASSWORD>@127.0.0.1:15432"
for DB in account litellm knowledge_db; do
    pg_dump "$DB_URL_BASE/$DB?sslmode=disable" | gzip > "$BACKUP_DIR/${DB}_$DATE.sql.gz"
done

echo "[INFO] 开始备份 Zitadel 认证库..."
docker exec postgresql-svc-plus pg_dump -U postgres zitadel | gzip > "$BACKUP_DIR/zitadel_$DATE.sql.gz"

echo "[INFO] 开始备份 Gitea 代码库..."
docker exec postgresql-svc-plus pg_dump -U postgres gitea | gzip > "$BACKUP_DIR/gitea_$DATE.sql.gz"

echo "[INFO] 清理 7 天前的旧备份..."
find $BACKUP_DIR -type f -name "*.sql.gz" -mtime +7 -delete

echo "[INFO] 备份完成！"
```

> [!TIP]
> 建议将备份文件加密并传输到异地 S3 兼容对象存储。我们已实现自动化脚本 `backup_postgres.sh`，支持对接 Vault 动态获取 S3 凭证并对数据进行高强度加密备份。

### 2.2 自动加密备份并传输至 S3 (推荐)

项目下新版备份脚本位于 [backup_postgres.sh](file:///Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit/scripts/backup/backup_postgres.sh)。该脚本会执行以下流程：
1. 运行 Python 辅助脚本，以 JWT 认证或 Token 方式登录 Vault (`https://vault.svc.plus`)。
2. 从 Vault 秘密路径 `kv/CICD/<env>/iac_state` 中动态拉取 S3 对象存储凭证（`TF_STATE_BUCKET`, `TF_STATE_ACCESS_KEY`, `TF_STATE_SECRET_KEY`, `TF_STATE_ENDPOINT`, `TF_STATE_REGION`）。
3. 使用 `pg_dump` 对 `postgresql-svc-plus` 里的每一个数据库做逻辑备份。
4. 使用 `openssl` 对导出的备份包执行高强度的对称加密（AES-256-CBC，PBKDF2 派生密钥）。
5. 调用 `aws s3 cp` 命令将加密后的冷备文件上传到指定的 S3 桶。

#### 2.2.1 本地部署方法

1. 将脚本拷贝至宿主机 `/opt/backup/backup_postgres.sh`，并确保拥有执行权限。
2. 在宿主机创建凭证配置文件 `/opt/backup/.backup_env`（权限设为 `chmod 600`）：
```bash
# 高强度对称加密口令（务必离线备份）
export BACKUP_ENCRYPTION_PASS="YourSuperSecurePassphrase"

# Vault 连接信息与鉴权
export VAULT_ADDR="https://vault.svc.plus"
export VAULT_TOKEN="your_vault_token" # 或者是 JWT 方式对应的环境变量 VAULT_JWT 和 VAULT_ROLE
```

#### 2.2.2 配置定时任务 (Cron)

通过 `crontab -e` 配置每天凌晨 3 点自动运行 S3 加密备份：
```cron
0 3 * * * /bin/bash -c "source /opt/backup/.backup_env && /bin/bash /opt/backup/backup_postgres.sh" >> /var/log/pg_backup_s3.log 2>&1
```


## 3. 灾难恢复与还原 (Restore)

当发生数据损坏或整机迁移时，请严格按照以下顺序进行恢复。

> [!WARNING]
> 在执行还原前，必须先停止产生写入流量的业务服务（如 Gitea, LiteLLM 等），仅保留 PostgreSQL 进程运行。

### 3.1 还原全局业务库
包含：`Account`, `LiteLLM`, `Knowledge DB (RAG)`
```bash
# 解压备份文件并使用凭证直接导入 (以 account 为例)
gunzip -c /var/backups/postgresql/account_YYYYMMDD.sql.gz | psql "postgres://svcplus_vps:<YOUR_PASSWORD>@127.0.0.1:15432/account?sslmode=disable"
```

### 3.2 还原 Zitadel 认证库
```bash
# 解压备份文件并导入
gunzip -c /var/backups/postgresql/zitadel_YYYYMMDD.sql.gz | docker exec -i postgresql-svc-plus psql -U postgres -d zitadel
```

### 3.3 还原 Gitea 代码库
```bash
# 解压备份文件并导入
gunzip -c /var/backups/postgresql/gitea_YYYYMMDD.sql.gz | docker exec -i postgresql-svc-plus psql -U postgres -d gitea
```

## 4. 高可用与进阶建议 (Disaster Recovery)

对于目前的单机多实例架构，逻辑备份（`pg_dumpall`）足够应付大多数场景，但存在 RPO (恢复点目标) 约为 24 小时的问题（取决于备份频率）。

> [!IMPORTANT]
> **提升容灾级别的建议：**
> 1. **增量备份 (WAL Archiving)**: 针对业务极其核心的 AI 核心服务库和 Gitea，可引入 `pgBackRest` 或 `WAL-G`，将物理 WAL 日志实时归档至 S3（MinIO）。这样可以将数据丢失风险（RPO）降低到分钟级别。
> 2. **应用级灾备**: 
>    - Vault Storage 的加解密密钥不能仅存在数据库中，请确保 Vault 的物理 Root Token/Unseal Keys 已被安全离线保存。
>    - Gitea 除了备份数据库，还必须定期备份宿主机上的 `/var/lib/gitea/data` (Git 仓库裸数据和 LFS 制品)。可以借助 Gitea 自带的 `gitea dump` 命令来实现数据 + 仓库的一体化备份。
