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

## 用户执行一次性 bootstrap

统一入口为 `bootstrap_prod_selfhost.sh`。入口会在
`~/.cache/platform-ops-toolkit/prod-selfhost-bootstrap/` 自动准备两个独立、
干净、固定 SHA 的源码 checkout；无需填写 `/path/to/pinned-*`。
缓存或显式 `--iac-dir` / `--gitops-dir` 不干净或版本不符时停止，绝不重置业务目录。
本地需要 Bash、Git、jq、Ruby、shasum、Terraform 1.10+，读取 Vault 还需
Vault CLI 与现有授权；私有 GitHub 仓库使用现有 Git/gh 授权。
`identity` 阶段无需 Python。`external-ip` 复用 IaC 原有共享资源渲染器，
其既有依赖为 Python、PyYAML 6.0.2、Jinja2 3.1.6；可通过
`IAC_RENDER_PYTHON` 选择已准备的解释器。自定义 Python bootstrap 控制器与
执行器均已删除，未新增 Python/Shell 双入口。

凭据来源：

- `kv/CICD/prod/gcp-bootstrap/xworktech` 的 `GCP_PROJECT_ID` 必须为
  `open-platform-prod`，由管理员按获批渠道配置短期 `GCP_ACCESS_TOKEN`。
- 也可在管理员进程环境注入 `GCP_BOOTSTRAP_ACCESS_TOKEN`，入口不要求某个个人账号登录。
- 用户可明确传入 `--bootstrap-account EMAIL`，由固定 IaC Shell owner 从该
  已授权本地登录取得短期 token。不得同时注入 token；未选择账号时不会自动
  使用个人身份。登录续期由用户完成，仅适用于这次 bootstrap。
- state 参数从 `kv/CICD/prod/iac_state` 读取；已按获批渠道完整注入的 `TF_STATE_*`
  环境合同可直接使用。不得创建另一个 bucket/key 代替原 state。
- 不在命令行、聊天、文档或 Git 中填写 token、密码或 Service Account key。
  两步完成后按现有 Vault 审批流程移除一次性 token；token 过期不代表 Vault 历史版本已清理。

从 Toolkit 根目录执行以下真实命令。检查步骤不读 Vault、不访问 GCP：

```bash
bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh \
  --stage identity --check

bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh \
  --stage identity --action plan \
  --bootstrap-account haitaopan@xworktech.com > /tmp/prod-bootstrap-identity-plan.json

jq . /tmp/prod-bootstrap-identity-plan.json
```

审查输出中的三个精确 IAM/API 目标与计划摘要，然后执行：

```bash
bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh \
  --stage identity --action apply \
  --bootstrap-account haitaopan@xworktech.com \
  --approved-plan-sha256 "$(jq -er .approved_plan_sha256 /tmp/prod-bootstrap-identity-plan.json)"
```

取得 `result=converged` 后，执行第二阶段；先阅读计划，再执行 apply：

```bash
bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh \
  --stage external-ip --action plan \
  --bootstrap-account haitaopan@xworktech.com > /tmp/prod-bootstrap-external-ip-plan.json

jq . /tmp/prod-bootstrap-external-ip-plan.json

bash scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh \
  --stage external-ip --action apply \
  --bootstrap-account haitaopan@xworktech.com \
  --approved-plan-sha256 "$(jq -er .approved_plan_sha256 /tmp/prod-bootstrap-external-ip-plan.json)"
```

第二步只修复外网策略，不创建 VM。上述本地账号可换成其他已获批账号；
若使用环境 token 或 Vault 短期 token，省略 `--bootstrap-account`。

`--check` 只证明固定源码合同，`plan` 只产生待审查计划；二者均不证明 live
bootstrap 完成。两份 apply 收敛回执也不等于资源部署、数据库一致性或主库切换。
私有临时 Terraform 工作区执行后清理；不发布原始 plan/state/provider 日志。
凭据缺失、403、API 未启用、state 缺失、计划删除/替换或摘要变化都会停止。

## 与主线的连接

2026-10-06 的 [资源 plan 37478158368](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478158368)
成功，计划为 5 新增、0 修改、0 删除；
[apply 37478514735](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478514735)
仍因 `orgpolicy.googleapis.com` 未启用及 `compute.firewalls.create` 缺失而失败。
该历史失败不能由 plan 成功推断为权限齐备。当前为**待用户执行一次性
bootstrap**；两步取得真实收敛回执后，再复核日常 OIDC 资源 plan/apply。

两步 bootstrap 收敛后，仍按：资源 → 初始化 → 单向复制 → 全业务一致性
→ 网关/CNAME 切换 → 生产验收。数据库切换前生产继续使用 Serverless。
若某一步部分成功，只在原 state 重新 plan 修复；不反向删除权限或重建数据盘。
历史 bootstrap executor 保持原合同；此入口为用户选择的一次性修复路径，
不新增 GitHub/Vault 授权 claim，不替换旧 UAT 流程，也不改变日常 OIDC 认证链。
