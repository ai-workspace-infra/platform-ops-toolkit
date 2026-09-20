# UAT Akamai Cloud Selfhost Profile

## 默认拓扑

UAT 的 `selfhost-orchestrator` 默认使用 `akamai-cloud` provider，并以
`target_domains=all` 执行完整的 Selfhost profile。资源声明位于 GitOps：

| 工作区 | 规格 | 用途 | GitOps 声明 |
| --- | --- | --- | --- |
| `web-saas` | 2C4G (`g6-standard-2`) | Web SaaS 服务节点 | `resources/svc.plus/uat/akamai/web-saas.yaml` |
| `open-platform` | 2C4G (`g6-standard-2`) | 迁移 `vault.svc.plus` 与 `observability.svc.plus` | `resources/svc.plus/uat/akamai/open-platform.yaml` |
| `ai-workspace` | 2C8G (`g8-dedicated-8-2`) | AI Workspace 套件 | `resources/svc.plus/uat/akamai/ai-workspace.yaml` |

UAT Agent Proxy 使用五区域矩阵：

- Akamai Cloud/Terraform：JP、US、SG。
- Ulighthost/existing：TW、PH。

existing 节点只从统一 inventory 和 Vault 读取连接事实，不由 Terraform 创建或销毁。

## 手动触发

在 `selfhost-orchestrator` 中选择：

```text
vault_env_path: uat
target_domains: all
cloud_provider: akamai-cloud
cloud_account: manbuzhe2026
operation: plan
include_external_agent_proxy: true
```

默认 `operation` 建议先使用 `plan`。确认计划无漂移后，再按变更审批执行
`infra` 或 `deploy`。workflow 会为该 profile 使用独立的 `selfhost` workspace 和
S3 state key，不复用单独的 `web-saas` state：

```text
terraform/uat/platform-ops-toolkit/akamai-cloud/manbuzhe2026/selfhost/terraform.tfstate
```

## 验证要点

1. Akamai 组合渲染应得到 6 台 Terraform 主机：3 台 Selfhost 服务节点和 3 台
   JP/US/SG Agent Proxy 节点。
2. Agent Proxy 矩阵应额外得到 TW/PH 两个 Ulighthost existing 节点，总计五个区域。
3. `open-platform` 的服务域名必须包含 `vault.svc.plus` 和
   `observability.svc.plus`。
4. UAT profile 不应读取或写入 PROD state，也不应执行 Ulighthost 节点的 Terraform
   apply/destroy。

## 凭据边界

Akamai Cloud 使用 `linode/linode` provider。`LINODE_TOKEN` 仍只从 Vault/OIDC
运行时注入；GitOps 文件只包含非敏感资源参数和 SSH 公钥，不提交 API token、密码或
私钥。
