# UAT Hybrid 多云资源复用与串行部署计划

状态：方案阶段；本文件不授权 Terraform apply/destroy、现有节点改规格、数据迁移或 DNS 切换。

## 目标与入口

`hybrid-orchestrator.yml` 是顶层 orchestrator，增加 `target_domains=all` 的 UAT 编排入口；它只调度 `selfhost-orchestrator.yml` 和 `serverless-orchestrator.yml`，不直接渲染 Terraform 或执行 Playbook。Selfhost 再根据 GitOps 矩阵路由到各 provider 的 IaC、existing adapter 和 Playbooks；Serverless 负责 Supabase、Cloud Run 与 Cloudflare 前端。一次选择 `all` 后，Hybrid 按下表顺序逐项等待子流程完成；每项都记录资源来源、state 或 existing 身份、健康检查与子运行链接。失败即停止后续项，不把已成功项当成待回滚的临时资源。`plan` 只做配置和只读事实核对，`deploy` 才调用子流程。

| 顺序 | 业务域 | 目标位置与规格 | 管理方式 | 工作负载 |
| --- | --- | --- | --- | --- |
| 1 | `open-platform` | Akamai Cloud，2C4G | 独立 Akamai Terraform state | Vault、Observability 等平台服务；先核实与现有共享服务的边界 |
| 2 | `web-saas` | GCP，复用所称的现有 Vault node 0，目标 2C4G | existing/应用部署；不得由 UAT Terraform 接管共享 Vault 的 state | Web SaaS Selfhost 后端；同时调用 Serverless 部署 Supabase、Cloud Run、Cloudflare Pages/Workers |
| 3 | `ai-workspace` | GCP Spot，4C8G | 独立 GCP Terraform state | AI Workspace 套件及监控探针 |
| 4 | `agent-proxy-jp` | AWS JP，2C2G | 独立 AWS Terraform state 或经核实的现有资源 | Gateway、Proxy-Server、CPA 同机混合部署 |
| 5 | `agent-proxy-us` | GCP US，2C2G | 独立 GCP Terraform state 或经核实的现有资源 | Gateway、Proxy-Server、CPA 同机混合部署 |
| 6 | `agent-proxy-sg` | Akamai Cloud SG，目标 2C2G | 独立 Akamai Terraform state | Gateway、Proxy-Server、CPA 同机混合部署 |
| 7 | `agent-proxy-tw` | 现有 TW 节点 | external inventory + Vault；无 Terraform 创建/销毁 | 对现有节点执行相同应用角色 |
| 8 | `agent-proxy-ph` | 现有 PH 节点 | external inventory + Vault；无 Terraform 创建/销毁 | 对现有节点执行相同应用角色 |

前端默认链路为 Cloudflare Pages 静态资源 + Cloudflare frontend-router/SSR/edge-gateway Workers；Cloud Run 与 Selfhost 按已验证的 Hybrid 策略服务 API。沿用 GitOps `topology/uat/hybrid/runtime-topology.yaml` 的现有域名和 Cloudflare 资源，不新建第二套前端入口。`Cloudpage` 在此按 Cloudflare Pages 理解。

## 编排契约

1. Hybrid 预检读取一份 GitOps UAT 资源矩阵，逐项校验 provider、真实账号、地区、规格、`create`/`existing` 身份、实例名、state key、应用域名、Vault 路径及监控端点。`target_domains=all` 只对该矩阵作串行扇出，不把单个 `cloud_provider` 输入套到八项上。
2. Hybrid 对每个基础设施或现有节点步骤只调用一次 Selfhost 子流程。Selfhost 按矩阵调用 Akamai、AWS 或 GCP 的对应 adapter；existing 项只读取 Vault/CMDB 事实。每个新建资源使用 `terraform/uat/<project>/<provider>/<account>/<namespace>/terraform.tfstate`，并分别锁定、plan、审批和 apply。读取统一的 `kv/data/CICD/uat/iac_state`，provider 凭据继续走各自的 Vault/OIDC 契约。复用的 Vault 节点保留原 state 归属，不能导入 Web SaaS state。
3. 基础节点完成 SSH、Caddy、运行时、监控探针与 CMDB 验收后才部署业务。Selfhost 工作流接收单项的 provider、资源身份与目标主机；Agent Proxy 的 Gateway、Proxy-Server、CPA 三角色必须在 playbook 中有明确的端口、进程、Caddy 路由、凭据及健康检查，避免覆盖现有 Gateway 配置。
4. Web SaaS 顺序是：Hybrid 等待 Selfhost 完成目标主机准备与业务部署 → 调用 Serverless `web-saas` 部署/验证（Supabase、Cloud Run、Pages/Workers）→ 校验 Hybrid edge-gateway 模式。Hybrid 只传递部署版本和环境上下文；Supabase 的写入职责需先与现有 Hybrid 单写者契约统一，不在编排层暗中更改数据库主从关系。
5. 各 Agent Proxy 与 Accounts 注册、XConnect Gateway/One 联动、监控心跳和区域域名验证均随本区域步骤完成。TW/PH 只走 external-node job。每步成功后才进入下一步，最终摘要列出八项实际执行结果、资源 ID、state key 或 existing 引用、子流水线链接与前端入口检查。
6. Hybrid `plan` 检查所有上述声明和目前的 Cloudflare 复用契约，不调用 `apply`、业务部署或 DNS 更新；`deploy` 在所有输入和资源事实核对通过后才能扇出。每个子运行必须由可追踪的关联 ID 识别，避免并行的 Actions 运行被误认成自己的结果。

## 现状差距与落地顺序

当前 `.github/workflows/hybrid-orchestrator.yml` 只验证 Serverless/Hybrid 边界并更新三个 edge-gateway Workers；它不调用 Selfhost 或 Serverless。Selfhost 的 `all` 固定扇出六个 Akamai namespace；GCP/AWS 的单地区 Agent Proxy 不受这个路由支持。Serverless 目前独立负责 Supabase、Cloud Run、Pages、Workers。这些都需要修改后才能声明混合矩阵已可部署。

- `open-platform` 的 Akamai 声明已是 `us-east / g6-standard-2`，匹配目标 2C4G；实际 state、服务所有权和旧节点迁移边界仍需只读验收。
- 所称 Vault node 0 在 GitOps 是 shared `vault-prod-0`，位于 `open-platform-prod / asia-east1-a`，规格 `e2-highcpu-2`（2C2G），且属于共享 Vault state。它既不是 2C4G，也不是独立的 UAT 资源。需要确认目标节点身份及复用许可；若确实复用它，须另列容量、隔离、备份和变更窗口，不能让 UAT 运行自动调整或销毁这台节点。[GCP E2 规格](https://docs.cloud.google.com/compute/docs/general-purpose-machines)。
- GCP `ai-workspace-workload.yaml` 目前声明 `e2-micro` Spot、最长运行 3600 秒，无法作为目标 4C8G 的长期业务节点。需要改规格并确定 Spot 被回收后的重建、持久数据和服务恢复方案；可评估 `e2-custom-4-8192`，以实际区域配额和计划为准。[GCP 自定义规格](https://docs.cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type)、[Spot 中断行为](https://docs.cloud.google.com/compute/docs/instances/spot)。
- AWS UAT JP 现有声明默认 `t4g.micro`（2C1G）且没有单独 `agent-proxy-jp` state；目标 2C2G 可评估 `t4g.small`，并确认 ARM 版 Gateway/Proxy-Server/CPA 镜像、现有实例是否已被其他 state 管理。[AWS T4g 规格](https://aws.amazon.com/ec2/instance-types/t4/)。
- GCP US 的现有 `agent-proxy-us-workload.yaml` 是 `e2-micro` Spot、最长一小时；需确定 2C2G 实例类型、是否继续 Spot、目标账号和网络/SSH 可达性。
- Akamai SG 的现有 `agent-proxy-sg.yaml` 是 `g6-standard-1`（1C2G）。目标 2C2G 需通过 Linode types API 与 `sg-sin-2` 容量查询选择真实可用 plan；在型号确定前不提交假定规格。已销毁的旧 SG state 不能视为现有主机。[Akamai 计划文档](https://techdocs.akamai.com/cloud-computing/docs/how-to-choose-a-compute-instance-plan)。
- TW/PH 已有 Ulighthost external 声明和 Vault 凭据路径；需读回 CMDB/Vault 中的实例 ID、SSH 连接、Caddy 入口和三角色运行状态。不能因为 `all` 中包含两项而触发 Terraform。
- 现有 Hybrid GitOps 契约规定 Selfhost PostgreSQL 单写、Supabase 副本且只对安全方法做 Cloud Run failover。若希望 Supabase 改作 Web SaaS 主库，应先更新数据流、迁移与回滚设计及契约测试，再改入口。当前计划保持该契约，直到业务决定变更。

实施顺序：先补齐 GitOps 资源身份与规格声明；再扩展各 provider 的单 namespace IaC/复用 adapter、Selfhost 地区路由和三角色 playbook；随后让 Hybrid 按上表顺序调度 Selfhost/Serverless，并记录子运行 ID；最后做 `plan`、逐项 UAT 验收、Cloudflare 入口及回滚演练。未完成这些差距前，`deploy` 应显式失败并指出缺项。Selfhost 与 Serverless 保持可单独运行，Hybrid 只负责统一入口、依赖顺序和结果汇总。

## 验收标准

- `plan` 展示八项顺序、provider、账号、区域、规格、创建或复用身份、state key/CMDB 引用，且零资源变更。
- 每个 Terraform namespace 独立锁定和 `plan 0 add / 0 change / 0 destroy`；复用的 Vault、TW、PH 节点没有 UAT 新 state。
- Web SaaS Selfhost 与 Serverless 的健康检查、Cloudflare Pages 静态资源、Workers API 路由、Supabase 数据关系均符合更新后的单写者契约。
- JP/US/SG/TW/PH 的 Gateway、Proxy-Server、CPA 各自健康，Accounts 心跳与 Observability Agent 正常；某一区域失败时后续步骤不启动。
- 最终摘要能追溯八项子流水线；反复部署不会重建现有资源或扩大 Terraform destroy 范围。
