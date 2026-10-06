# PROD Selfhost 主线交付状态（2026-10-06）

## 主线与边界

GitOps 声明 → IaC 资源/CMDB → Playbooks 持久盘、主机与新空库 schema → Accounts migratectl 用户/身份逻辑复制及完整业务数据 owner → 全业务一致性与单写者回执 → Edge Gateway API 入口切换 → 生产业务验收。

- `xworktech.com` 保留品牌/法律/支持与上架审核材料；`console.svc.plus` 保留控制台入口。
- `accounts.svc.plus` / `billing.svc.plus` 通过模式限定 CNAME 与原始 Host Worker Routes 接入 Edge Gateway。
- Serverless 是 Cloud Run + PROD Supabase；Selfhost 是 `open-platform-prod / web-saas-prod` all-in-one + PostgreSQL。
- PROD Supabase 为专用只读来源；按规范化 email 匹配，PROD Proxy UUID、身份、订阅、额度、账本保留。身份复制不能替代全业务一致性。
- 日常资源部署使用 GitHub OIDC/Vault/WIF。首次 bootstrap 或权限合同修复是独立的一次性操作，不以个人 GCP 登录作为日常发布前置。

## 已确认的资源事实

GitOps [#391](https://github.com/ai-workspace-infra/gitops/pull/391) 已合并：`resources/svc.plus/prod/gcp/web-saas.yaml`，STANDARD e2-medium、独立 50 GB 数据盘、删除保护与 OS Login；沿用 `terraform/prod/svc.plus/gcp-cloud/xworktech/web-saas/terraform.tfstate`。

- [首次 plan 37458022020](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37458022020)：审批环境 `production` 与既有 `prod` WIF claim 不匹配。
- [对齐 plan 37460508241](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37460508241)：既有 `prod` OIDC 成功；8 新增、0 修改、0 删除。
- [apply 37461248828](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37461248828)：OIDC 成功，网络/子网/独立盘创建；防火墙权限、Organization Policy API 和外网 IP 策略阻挡后续资源，VM/CMDB 未完成。

本次代码将 Selfhost 控制器的 PROD 审批环境统一为 `prod`，沿用已配置 required reviewer。没有修改 WIF subject、IAM 权限或现有 Terraform state。

## 资源 bootstrap 修复的具体合同

一次性 bootstrap principal 需核对并收敛现有 `github-actions-prod@open-platform-prod.iam.gserviceaccount.com` 的项目角色。既有 IaC identity bootstrap 声明包含 `roles/compute.securityAdmin`，但实际 apply 未具备 `compute.firewalls.create`；源码声明不是实际授权证明。

1. 用具备权限的 bootstrap principal 核对现有 IAM，按现有声明补齐项目范围的防火墙管理能力。
2. bootstrap 启用 `orgpolicy.googleapis.com`；外网 IP 策略由组织策略管理员按固定 GitOps allowlist 收敛，只允许声明的实例，不放开全部实例。
3. 确认日常 runtime identity 对项目、CMDB 与 OS Login 的能力；不得授予日常 deployer 组织级管理员权限作为快捷修复。
4. 使用同一资源 state 做增量 plan，保留已创建网络/子网/盘；删除/替换即停止。仅在 plan 审查通过后重新 apply。

当前环境的 bootstrap Vault 记录只有项目 ID；没有可用的 bootstrap 凭据。不能以日常 deployer 自行提权，也不反复要求个人账号登录。完成上述一次性权限修复是 VM 创建的外部前提。

## 尚待完成的代码与运行门槛

| 项目 | 状态 |
| --- | --- |
| PROD `deploy+init` 支持 | 仍待 Playbooks 精确目标/独立盘/空库 owner 与 caller 固定 SHA 集成；当前 UAT-only 限制保留 |
| 最新 schema 与容器构件 | Init SQL 仅适用于不存在或真实空库，必须与不可变 Accounts release 匹配；非空库禁止重建 |
| migratectl + 全业务复制 | migratectl 当前为 Users/Identities/Sessions；订阅、额度、账本与其他业务表的完整 owner 尚待集成 |
| GTM / CNAME | Edge 与 IaC owner 在独立 PR 中准备；旧 DNS publisher 仍可能重绑 API，caller 迁移前不启用新 GitOps 别名 |
| 主库切换 | 来源只读基线已完成；目标全业务一致性、最终追平与可信切换回执尚未完成，生产维持 Serverless |
| UAT → PROD Full 晋级 | UAT 两跳同步、升级/回退/再次升级与业务资格单独验收；新 PROD 空库不构成 Full 升级资格 |

详细架构与免费额度见知识白皮书 7.2.1–7.2.2，八项主线任务见 12.3；文档 [knowledge #106](https://github.com/ai-workspace-services/knowledge/pull/106) 已合并。
