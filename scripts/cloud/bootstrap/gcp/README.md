# GCP bootstrap Shell 入口

| 脚本 | 负责范围 |
| --- | --- |
| `bootstrap_prod_selfhost.sh` | PROD 一次性修复控制入口：自动准备固定源码，读取授权/state 合同，调用 IaC Shell owner。IAM/API → 精确外网策略分别审查执行 |
| `bootstrap_gcp_auth_kv.sh` | 原有一次性 Vault 凭据 write/check/revoke；不自动串入 PROD 修复 |
| `bootstrap_gcp_iam_kv.sh` | 原有 IAM/Vault integration 入口；不等于项目资源权限已经收敛 |
| `bootstrap_shared_iac_state_kv.sh` | 原有共享 state 的 Vault 合同 |
| `resolve_github_oidc_config.sh` | 解析、校验 GitHub OIDC 声明 |
| `seed_shared_external_ip_policy.sh` | 原有 shared-only 外网策略；不能用于 PROD 绕过 Terraform state |
| `gcp_account_migration.sh` | 原有账号迁移流程，与本次资源修复分开执行 |

用户从 Toolkit 根目录执行：

```bash
bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh --stage identity --check
```

完整 plan → 审查 → apply 命令见 [PROD-SELFHOST.md](PROD-SELFHOST.md)。
自定义 bootstrap 控制与执行均使用 Shell，执行职责归固定版本 IaC；
不把历史脚本串成自动提权、重复 state 或跨环境写入的一键脚本。
日常部署使用 GitHub OIDC。资源修复回执不批准数据库切换。
