# GitHub Actions Composite Actions 与 Vault SMTP 迁移

## 目标

减少 workflow 中重复的 runner 初始化与 Terraform 命令 step，同时保持业务
部署、DNS、迁移和快照脚本的独立诊断边界。LandingZone 邮件通知不再消费 GitHub
Actions Secret，统一使用 GitHub OIDC 认证后从 Vault 读取。

## 范围与边界

| 范围 | 实施方式 | 不做的事 |
| --- | --- | --- |
| Runner 初始化 | 新建 `setup-deployment-runner` Composite Action | 不把领域部署脚本合并成巨型 action |
| Terraform 命令 | 新建 `terraform-command` Composite Action | 不改变 Terraform 参数或执行顺序 |
| LandingZone SMTP | Vault KV v2 环境隔离读取 | 不把凭据回写到 GitHub Secrets |
| 目录可读性 | 删除已被 action 取代的重复 common 脚本 | 不删除单用途业务脚本与测试 |

## 实施计划

### P0 — Vault SMTP 凭据迁移前置条件

在每个 LandingZone 可部署环境的 Vault KV v2 路径写入以下键：

```text
kv/data/CICD/sit   SMTP_USERNAME, SMTP_PASSWORD
kv/data/CICD/uat   SMTP_USERNAME, SMTP_PASSWORD
kv/data/CICD/prod  SMTP_USERNAME, SMTP_PASSWORD
```

工作流使用既有的 `github-actions-platform-ops-toolkit-<env>` OIDC role。迁移
完成后删除 GitHub Actions 的 `SMTP_PASSWORD` repository/environment secret。

### P1 — 收敛部署 Runner 初始化

新增 `setup-deployment-runner`，按输入组合执行：

1. 写入并校验 SSH 私钥；
2. 等待目标主机 SSH；
3. 可选等待首启 package lock 收敛；
4. 安装 Ansible 与 `hvac`；
5. 可选断言 Ansible inventory 中的目标真实可达。

迁移 Platform Ops、Action Runner 与 Data Migration 的重复 step，随后删除被完全
取代的 `common_*` SSH/Ansible 脚本及重复 migration SSH key 脚本。

状态：已完成。P1 已通过 `setup-deployment-runner` 接入 Platform Ops、Action Runner
和 Data Migration；已删除被完全取代的 SSH/Ansible 初始化脚本。Action 现在会先检测
Runner 上是否已有 `ansible` 与 `hvac`，仅在缺失时执行一次安装，避免矩阵 job 重复安装
和重复拉取依赖。`common_require_env.sh` 仍作为业务脚本共享库保留，未被误删。

### P2 — 收敛 Terraform 命令

新增 `terraform-command`，接收 command、working directory 与 config directory。
迁移 account matrix、resources matrix、LandingZone 的 init/apply/output 与 skip
step；保留 LandingZone 的专用 plan 脚本。

### P3 — 验证与回滚

- YAML 解析、workflow gating、脚本可执行位检查；
- 对 Composite Action shell 执行 `bash -n`；
- PR 事件中部署 job 仍应按环境路由规则跳过；
- 回滚仅需 revert 本 PR；Vault SMTP 键可以保留，不会暴露凭据。

## 完成标准

- workflow 不再引用已删除的 common SSH、Ansible 或 Terraform 脚本；
- LandingZone workflow 不再含 `secrets.SMTP_PASSWORD` 或 `workflow_call.secrets`；
- SMTP 仅通过 Vault OIDC 输出传入通知脚本；
- 业务领域脚本、失败诊断与 job 数量保持不变。
