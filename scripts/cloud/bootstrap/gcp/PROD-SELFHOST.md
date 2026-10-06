# PROD Selfhost 一次性 bootstrap

本目录提供控制入口；实际 GCP IAM/API、组织策略与 Terraform state 操作归
固定 SHA 的 `iac_modules` owner。入口不会使用日常 runtime 身份自行提权。
适用项目仅 `open-platform-prod`，账号仅 `xworktech`。

## 修复范围与执行顺序

| 步骤 | 收敛内容 | 后续门槛 |
| --- | --- | --- |
| `identity` | 项目内 `compute.securityAdmin`、`orgpolicy.policyViewer`；启用 `orgpolicy.googleapis.com` | 原 WIF/Service Account state 必须存在；不改 issuer、audience 或 subject |
| `external-ip` | 项目 `compute.vmExternalIpAccess` 仅允许 `web-saas-prod` | 使用原 Web SaaS state；保留已有网络、子网与独立数据盘 |
| 日常部署 | GitHub OIDC → Vault → WIF → 完整资源 plan/apply | bootstrap 两步均收敛；完整 plan 不得删除或替换现有资源 |

每一步都先 plan，再用审查过的 `approved_plan_sha256` apply。IaC 会重新生成
计划并核对摘要，再应用保存的计划；执行后再次 plan 验证 no-op。摘要绑定固定
源码、原 state lineage/serial、目标地址、动作和完整目标变化。状态发生变化时
重新 plan，不沿用旧摘要。存在未声明的外网许可或复杂策略时停止并独立审查。

管理员需具备项目 IAM/API 启用权限，以及既有组织策略管理权限。
日常 deployer 只授予项目内策略读取权限，不授予 `orgpolicy.policyAdmin`。
参考 [GCP Organization Policy 角色](https://docs.cloud.google.com/iam/docs/roles-permissions/orgpolicy)。

## 管理员执行

准备两个独立、干净的 checkout，分别检出控制脚本内 `IAC_REF` 和 `GITOPS_REF`
标明的完整 commit。不要重置有未提交业务修改的工作目录。
本地运行环境需 Git、Python 3.10+、PyYAML 6.0.2、Jinja2 3.1.6、Terraform 1.10+；
需要读取 Vault 时还需 Vault CLI 与现有授权。

凭据来源：

- `kv/CICD/prod/gcp-bootstrap/xworktech` 的 `GCP_PROJECT_ID` 必须为
  `open-platform-prod`，由管理员按获批渠道配置短期 `GCP_ACCESS_TOKEN`。
- 也可在管理员进程环境注入 `GCP_BOOTSTRAP_ACCESS_TOKEN`，入口不要求某个个人账号登录。
- state 参数从 `kv/CICD/prod/iac_state` 读取；已按获批渠道完整注入的 `TF_STATE_*`
  环境合同可直接使用。不得创建另一个 bucket/key 代替原 state。
- 不在命令行、聊天、文档或 Git 中填写 token、密码或 Service Account key。
  两步完成后按现有 Vault 审批流程移除一次性 token；token 过期不代表 Vault 历史版本已清理。

从 Toolkit 根目录执行，以下路径由管理员替换成准备好的 checkout：

```bash
python3 scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.py \
  --iac-dir /path/to/pinned-iac \
  --gitops-dir /path/to/pinned-gitops \
  --stage identity --check

python3 scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.py \
  --iac-dir /path/to/pinned-iac \
  --gitops-dir /path/to/pinned-gitops \
  --stage identity --action plan
```

审查输出中的三个精确 IAM/API 目标与计划摘要，然后执行：

```bash
python3 scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.py \
  --iac-dir /path/to/pinned-iac \
  --gitops-dir /path/to/pinned-gitops \
  --stage identity --action apply \
  --approved-plan-sha256 'YOUR_REVIEWED_PLAN_SHA256'
```

取得 `result=converged` 后，按相同 plan → 审查 → apply 顺序执行
`--stage external-ip`，使用该阶段独立的摘要。第二步不会创建 VM。

`--check` 只证明固定源码合同，`plan` 只产生待审查计划；二者均不证明 live
bootstrap 完成。两份 apply 收敛回执也不等于资源部署、数据库一致性或主库切换。
私有临时 Terraform 工作区执行后清理；不发布原始 plan/state/provider 日志。
凭据缺失、403、API 未启用、state 缺失、计划删除/替换或摘要变化都会停止。

## 与主线的连接

2026-10-06 的 [资源 plan 37478158368](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478158368)
成功，计划为 5 新增、0 修改、0 删除；
[apply 37478514735](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478514735)
仍因 `orgpolicy.googleapis.com` 未启用及 `compute.firewalls.create` 缺失而失败。
这说明管理员修复尚未实际生效，不能从 plan 成功推断创建权限齐备。

两步 bootstrap 收敛后，仍按：资源 → 初始化 → 单向复制 → 全业务一致性
→ 网关/CNAME 切换 → 生产验收。数据库切换前生产继续使用 Serverless。
若某一步部分成功，只在原 state 重新 plan 修复；不反向删除权限或重建数据盘。
历史 bootstrap executor 保持冻结；此入口为管理员选择的一次性修复路径，
不新增 GitHub/Vault 授权 claim，不替换旧 UAT 流程，也不改变日常 OIDC 认证链。
