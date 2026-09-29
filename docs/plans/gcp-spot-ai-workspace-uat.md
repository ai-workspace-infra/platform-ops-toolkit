# AI Workspace UAT：GCP Spot 独立实例

UAT Hybrid 的 `ai-workspace` 由 GitOps `topology/uat/hybrid/resource-matrix.json` 路由到 GCP Terraform。实例规格、区域、项目、网络、SSH 来源 CIDR、网络标签和 Ansible 分组来自 `resources/svc.plus/uat/gcp/ai-workspace.yaml`，不是 Toolkit 工作流中的固定常量。旧私网主机 `10.79.0.7` 不参与本次部署，也不导入新 state。

## 创建前门禁

1. 核对 GitOps 声明的目标 project、zone、machine type、Spot 生命周期和 SSH CIDR。当前声明的 `0.0.0.0/0` 仅允许密钥登录，但仍是全网可达；若 Runner 有固定出口，先改为其 `/32` 再执行。
2. 项目级 `compute.vmExternalIpAccess` 现有 allowlist 要允许声明中的实例。列表的 GitOps 来源是 `resources/xworktech.com/uat/gcp/open-platform-uat.yaml` 的 `external_ip_allowed_instances`。它由独立 GCP 平台 state 拥有；不要让 `ai-workspace` state 再管理同一 Org Policy。变更 live policy 前，先只读核对当前值并保留其他已允许的主机。
3. 确认 Vault 的 UAT GCP OIDC 身份可操作声明的 project，且 UAT 部署 SSH 私钥存在。工作流从 Vault 私钥派生公钥注入 VM metadata；公钥为空时 Terraform 会拒绝创建公网 VM。
4. 核对 `terraform/uat/svc.plus/gcp-cloud/xworktech/ai-workspace/terraform.tfstate` 的现有资源及 plan。禁止对旧 Akamai 或 existing-host state 做无映射迁移。

## 验证

在 `main` 上以 `target_domains=ai-workspace`、`cloud_provider=gcp-cloud`、`cloud_account=xworktech`、`vault_env_path=uat`、`target_domain_base=onwalk.net` 运行 Selfhost Orchestrator 的 `operation=plan`。确认计划只涉及独立 Spot VM、其网络及入站 SSH 规则，且不会修改或删除其他 namespace。

审批计划后用相同参数运行 `operation=infra`；确认 CMDB 中该 VM 的公网地址和 `ai_workspace` 分组，再运行 `operation=deploy` 执行 Playbook 与监控探针。Spot 可能被 GCP 抢占并停止；不要将本地盘作为 QMD 等唯一持久数据来源。所有 destroy 均需单独审批，不能因 Spot 类型而默认触发。
