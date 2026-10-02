# AI Workspace UAT：Existing Selfhost 默认路径

UAT Hybrid 的 `ai-workspace` 默认由 GitOps `topology/uat/hybrid/resource-matrix.json` 路由到 Existing Selfhost。日常 UAT/PROD 发布不主动创建 AI Workspace 云主机，也不把现有主机导入新 Terraform state；现有 provider 资源声明保留，仅供显式、单独审批的 IaC 创建流程使用。

## 创建前门禁

1. 核对 GitOps 声明的目标 project、zone、machine type、Spot 生命周期和 SSH CIDR。当前声明的 `0.0.0.0/0` 仅允许密钥登录，但仍是全网可达；若 Runner 有固定出口，先改为其 `/32` 再执行。
2. 项目级 `compute.vmExternalIpAccess` 现有 allowlist 要允许声明中的实例。列表的 GitOps 来源是 `resources/xworktech.com/uat/gcp/open-platform-uat.yaml` 的 `external_ip_allowed_instances`。它由独立 GCP 平台 state 拥有；不要让 `ai-workspace` state 再管理同一 Org Policy。变更 live policy 前，先只读核对当前值并保留其他已允许的主机。
3. 确认 Vault 的 UAT GCP OIDC 身份可操作声明的 project，且 UAT 部署 SSH 私钥存在。工作流从 Vault 私钥派生公钥注入 VM metadata；公钥为空时 Terraform 会拒绝创建公网 VM。
4. 核对 `terraform/uat/svc.plus/gcp-cloud/xworktech/ai-workspace/terraform.tfstate` 的现有资源及 plan。禁止对旧 Akamai 或 existing-host state 做无映射迁移。

## 验证

日常发布使用 `target_domains=all`，由 Hybrid 消费 existing-selfhost 声明；AI Workspace 只执行已有主机上的 Playbook、监控和健康检查。

如果确实需要创建新的 Spot VM，必须在 GCP UAT workload sequence 中显式设置 `provision_ai_workspace=true`，再单独执行 plan、审批和 apply。

不得因为 GitOps 中仍保留 provider 资源声明就自动创建或 destroy VM；任何显式创建仍需确认 CMDB、生命周期和回滚范围。
