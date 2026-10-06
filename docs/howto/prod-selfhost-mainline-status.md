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
- [增量 plan 37478158368](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478158368)：固定 IaC/GitOps SHA 与既有 OIDC 成功，5 新增、0 修改、0 删除，保留已创建资源。
- [增量 apply 37478514735](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478514735)：仍因 `orgpolicy.googleapis.com` 未启用及 `compute.firewalls.create` 缺失失败；没有新建 VM。plan 成功不代表创建授权已生效。

[Toolkit #1325](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1325) 已合并，将 Selfhost 控制器的 PROD 审批环境统一为 `prod`，沿用已配置 required reviewer。没有修改 WIF subject、IAM 权限或现有 Terraform state。

## 资源 bootstrap 修复的具体合同

一次性 bootstrap principal 需核对并收敛现有 `github-actions-prod@open-platform-prod.iam.gserviceaccount.com` 的项目角色。既有 IaC identity bootstrap 声明包含 `roles/compute.securityAdmin`，但实际 apply 未具备 `compute.firewalls.create`；源码声明不是实际授权证明。

1. 用具备权限的 bootstrap principal 核对现有 IAM，按现有声明补齐项目范围的防火墙管理能力。
2. bootstrap 启用 `orgpolicy.googleapis.com`；外网 IP 策略由组织策略管理员按固定 GitOps allowlist 收敛，只允许声明的实例，不放开全部实例。
3. 确认日常 runtime identity 对项目、CMDB 与 OS Login 的能力；不得授予日常 deployer 组织级管理员权限作为快捷修复。
4. 使用同一资源 state 做增量 plan，保留已创建网络/子网/盘；删除/替换即停止。仅在 plan 审查通过后重新 apply。

当前环境的 bootstrap Vault 记录只有项目 ID；没有可用的 bootstrap 凭据。不能以日常 deployer 自行提权，也不反复要求个人账号登录。完成上述一次性权限修复是 VM 创建的外部前提。

当前为**待用户执行一次性 bootstrap**。统一 Shell 控制入口自动准备固定
IaC/GitOps 源码，无需填写占位 checkout 路径。操作说明见
[`scripts/cloud/bootstrap/gcp/PROD-SELFHOST.md`](../../scripts/cloud/bootstrap/gcp/PROD-SELFHOST.md)。
分 `identity`、`external-ip` 两个阶段，分别 plan → 审查摘要 → apply → 再次 plan 验证 no-op。
仅调用固定 IaC owner；沿用原 state，拒绝删除/替换与越界写入，不改变日常 OIDC 链。
旧声明与现有 Vault bucket 的差异由已合并的
[GitOps #394](https://github.com/ai-workspace-infra/gitops/pull/394) 对齐；不迁移 bucket 或 state key。
实际修复合同源自 [IaC #401](https://github.com/ai-workspace-infra/iac_modules/pull/401)，现统一为 Shell owner，
控制入口固定该 owner 与声明 SHA，不使用可变 main 作为执行源码。
该入口源码/检查通过不等于管理员已应用 live 修复。

## 尚待完成的代码与运行门槛

| 项目 | 状态 |
| --- | --- |
| PROD `deploy+init` 支持 | GitOps #393 的 PROD Doco-CD 与 `/data/postgresql` bind、Playbooks #592 的独立盘/精确 CMDB/空库 owner 已合并；Linux CI 证明格式化、挂载、幂等恢复与 fail-closed。仍待 PROD caller 集成与真实 VM，当前 UAT-only DB operation 限制保留 |
| 最新 schema 与容器构件 | Init SQL 仅适用于不存在或真实空库，必须与不可变 Accounts release 匹配；非空库禁止重建 |
| migratectl + 全业务复制 | migratectl 当前为 Users/Identities/Sessions；订阅、额度、账本与其他业务表的完整 owner 尚待集成 |
| GTM / CNAME | Edge #28/#29、IaC #398/#400、Toolkit #1326 已合并；Serverless DNS caller 使用固定 IaC reusable workflow，PROD gateway 改走受保护的 Edge 入口。GitOps #392 激活仍待 Vault 合同及真实 UAT/生产入口证据 |
| 主库切换 | 来源只读基线已完成；目标全业务一致性、最终追平与可信切换回执尚未完成，生产维持 Serverless |
| UAT → PROD Full 晋级 | UAT 两跳同步、升级/回退/再次升级与业务资格单独验收；新 PROD 空库不构成 Full 升级资格 |

详细架构与免费额度见知识白皮书 7.2.1–7.2.2，八项主线任务见 12.3；文档 [knowledge #106](https://github.com/ai-workspace-services/knowledge/pull/106) 已合并。

## 本次 owner/caller 改造与验收顺序

- IaC [#399](https://github.com/ai-workspace-infra/iac_modules/pull/399)：一次性 bootstrap API 声明与 VM 依赖；本地 15 项 GCP 契约和 Terraform validate 通过，不代表 live IAM 已应用。
- IaC [#398](https://github.com/ai-workspace-infra/iac_modules/pull/398)、[#400](https://github.com/ai-workspace-infra/iac_modules/pull/400) 已合并 provider 与精确 GitOps SHA、caller/environment 校验、reusable workflow 和稳定 API 别名保护；21 项 provider/请求检查以及迁移后的 legacy/GTM DNS 行为测试通过。
- Edge [#28](https://github.com/ai-workspace-services/edge-gateway/pull/28)、[#29](https://github.com/ai-workspace-services/edge-gateway/pull/29) 已合并 Accounts/Billing 共同模式、完整数据切换门槛和同 run/commit/计划的限时部署授权。旧 PROD controller 不能绕过该入口。
- GitOps [#392](https://github.com/ai-workspace-infra/gitops/pull/392)：Accounts/Billing 的模式限定 CNAME 声明，caller/owner 迁移验证后才能激活。

本分支只做控制面：Serverless preflight 固定 GitOps SHA，所有后续 lane 使用同一 SHA；Cloudflare 变更交给 `iac_modules/.github/workflows/cloudflare-serverless-domains.yml@a7ac40fb0c3e620bdec89edd72b172afefc1f2ee`。稳定 GTM API 别名由 Edge 的 guarded caller 单独调用 IaC action；Serverless publisher 不得重绑它们。品牌主页、控制台、CORS 与静态资源的 HTTP 检查保留。所有 PROD legacy Edge 部署均跳过；UAT 旧发布入口保持现状。

冻结的旧 DNS executor 暂时保留，仅供现有回归检查；真实 UAT owner → caller 验证后再删除。激活新 GitOps 之前须停止或等待使用旧 owner/Edge source 的既有 run 结束，避免旧调用方覆盖入口。新 reusable workflow 的 Vault job/workflow claims 和环境保护须实际核对；PR/local CI 不证明授权可用。

SIT/UAT/PROD 现有 Vault role 源码已增加上述唯一固定 IaC workflow SHA；repository、既有 ref 限制和 token policy 未扩大。合并后按既有 Vault role apply 流程同步，再做真实 owner/caller 验证。源码 allowlist 不代表 live Vault 已应用，PROD 仍只允许版本 tag/release 分支。

合并顺序为 IaC owner → Toolkit caller 与 Edge guarded 发布入口 → GitOps 声明激活。实际主库切换继续等待完整业务一致性和单写者回执，身份复制、路由 plan 或 DNS 收敛均不能替代它。
