# UAT Hybrid 多云资源复用与串行部署计划

> 更新（2026-09-29）：AI Workspace UAT 不再默认复用 `10.79.0.7`。最新的 GitOps Hybrid 矩阵声明 GCP Spot 4C8G 独立 Terraform namespace；本文件下文涉及该旧主机的段落仅保留历史背景，不可作为当前 dispatch 输入。运行时以 GitOps 矩阵及 `resources/svc.plus/uat/gcp/ai-workspace.yaml` 为准。当前操作与验收见 [GCP Spot UAT AI Workspace runbook](gcp-spot-ai-workspace-uat.md)。

状态：编排契约已实现，真实 apply/destroy、现有节点改规格、数据迁移和 DNS 切换仍需单独审批。

关联任务：Epic [platform-ops-toolkit#838](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/838)、基础设施阶段 [#845](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/845)、业务部署与迁移阶段 [#846](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/846)。本文是上述任务的 Hybrid 多云演进方案；若 issue 中的旧六 Akamai namespace 与本文八项混合矩阵冲突，以后续经审批的 GitOps profile 和对应变更 PR 为准，不静默覆盖历史 state。

## 目标与入口

`hybrid-orchestrator.yml` 是唯一的顶层 orchestrator，增加 `target_domains=all` 的 UAT 编排入口；它只编排和调用 `selfhost-orchestrator.yml` 与 `serverless-orchestrator.yml`，不直接渲染 Terraform、执行 Playbook 或复制两个子工作流的实现。Selfhost 再根据 GitOps 矩阵路由到各 provider 的 IaC、existing adapter、PostgreSQL 后端和 Playbooks；Serverless 负责 Supabase、Cloud Run 与 Cloudflare 前端。一次选择 `all` 后，Hybrid 按下表顺序逐项等待子流程完成；每项都记录资源来源、state 或 existing 身份、健康检查与子运行链接。失败即停止后续项，不把已成功项当成待回滚的临时资源。`plan` 只做配置和只读事实核对，`deploy` 才调用子流程。`deploy` 采用两阶段门禁：先完成 `open-platform` 以及 JP/US/SG 三个 Terraform 资源，再调用一次可配置的 XConnect Zero Gateway（UAT 默认 `tw-xconnect.svc.plus`）；XConnect 成功后才进入 Web SaaS、AI Workspace、区域 Agent Proxy 应用和 TW/PH existing 节点部署。这样 `10.79.0.7` existing-selfhost、TW/PH existing 节点不会在 UAT 零信任网络未打通时开始 Playbook。

| 顺序 | 业务域 | 目标位置与规格 | 管理方式 | 工作负载 |
| --- | --- | --- | --- | --- |
| 1 | `open-platform` | GCP，2C4G | 独立 GCP Terraform state | Vault、IAM、Observability 等平台服务；先核实与现有共享服务的边界 |
| 2 | `web-saas` | GCP，复用所称的现有 Vault node 0，目标 2C4G | existing/应用部署；不得由 UAT Terraform 接管共享 Vault 的 state | Web SaaS Selfhost 后端；同时调用 Serverless 部署 Supabase、Cloud Run、Cloudflare Pages/Workers |
| 3 | `ai-workspace` | 复用 `10.79.0.7`，逻辑 provider 为 GCP，4C8G | existing-selfhost；无 Terraform state | 经 XConnect 打通后部署 AI Workspace 套件及监控探针 |
| 4 | `agent-proxy-jp` | AWS JP，2C2G | 独立 AWS Terraform state 或经核实的现有资源 | Gateway、Proxy-Server、CPA 同机混合部署 |
| 5 | `agent-proxy-us` | GCP US，2C2G | 独立 GCP Terraform state 或经核实的现有资源 | Gateway、Proxy-Server、CPA 同机混合部署 |
| 6 | `agent-proxy-sg` | Akamai Cloud SG，目标 2C2G | 独立 Akamai Terraform state | Gateway、Proxy-Server、CPA 同机混合部署 |
| 7 | `agent-proxy-tw` | 现有 TW 节点 | external inventory + Vault；无 Terraform 创建/销毁 | 对现有节点执行相同应用角色 |
| 8 | `agent-proxy-ph` | 现有 PH 节点 | external inventory + Vault；无 Terraform 创建/销毁 | 对现有节点执行相同应用角色 |

前端默认链路为 Cloudflare Pages 静态资源 + Cloudflare frontend-router/SSR/edge-gateway Workers。Worker 是唯一公网 SSR/API gateway，默认采用 `selfhost-first` 路由：优先把 SSR 和后端 API 请求送到 Selfhost API，由 Selfhost API 访问 PostgreSQL；Cloud Run 是可配置的回退、溢出或指定路由目标，不是默认主流量入口。沿用 GitOps `topology/uat/hybrid/runtime-topology.yaml` 的现有域名和 Cloudflare 资源，不新建第二套前端入口。`Cloudpage` 在此统一指 Cloudflare Pages。

```text
Client
  -> Cloudflare Pages (静态前端)
  -> Cloudflare Worker (SSR + API gateway)
       -> Selfhost API -> PostgreSQL        # 默认、低成本主路径
       -> Cloud Run API                     # 健康回退/溢出/显式路由
```

Worker 不直接连接 PostgreSQL，也不持有数据库管理员凭据。默认只有 `GET`、`HEAD` 等安全请求允许在 Selfhost 不健康时自动回退 Cloud Run；写请求继续固定到 Selfhost 单写 API，除非 Cloud Run 已使用同一数据写入契约、幂等键和事务边界并通过专门验收。这样可以降低 Cloud Run 流量成本，同时避免自动故障切换产生双写、重复提交或数据库分叉。

## 编排契约

1. Hybrid 预检读取一份 GitOps UAT 资源矩阵，逐项校验 provider、真实账号、地区、规格、`create`/`existing` 身份、实例名、state key、应用域名、Vault 路径及监控端点。`target_domains=all` 只对该矩阵作串行扇出，不把单个 `cloud_provider` 输入套到八项上。
2. Hybrid 对每个基础设施或现有节点步骤只调用一次 Selfhost 子流程。Selfhost 按 provider registry 调用 AWS、GCP、Azure、Vultr、Akamai 或 UCloud 的 Terraform adapter；existing 项只读取 Vault/CMDB 事实，`existing-selfhost` 只对已存在主机执行 Playbook。每个新建资源使用 `terraform/uat/<project>/<provider>/<account>/<namespace>/terraform.tfstate`，并分别锁定、plan、审批和 apply。读取统一的 `kv/data/CICD/uat/iac_state`，provider 凭据继续走各自的 Vault/OIDC 契约。复用的 Vault 节点、`10.79.0.7`、TW/PH existing 节点均保留原 state 归属，不能导入业务 namespace state；`ai-workspace` 只执行 existing-selfhost Playbook。
3. 基础节点完成 SSH、Caddy、运行时、监控探针与 CMDB 验收后才部署业务。Selfhost 工作流接收单项的 provider、资源身份与目标主机；Agent Proxy 的 Gateway、Proxy-Server、CPA 三角色必须在 playbook 中有明确的端口、进程、Caddy 路由、凭据及健康检查，避免覆盖现有 Gateway 配置。
4. Web SaaS 顺序是：Hybrid 等待 Selfhost 完成目标主机准备与业务部署 → 调用 Serverless `web-saas` 部署/验证（Supabase、Cloud Run、Pages/Workers）→ 校验 Hybrid edge-gateway 模式。Hybrid 只传递部署版本和环境上下文；Supabase 的写入职责需先与现有 Hybrid 单写者契约统一，不在编排层暗中更改数据库主从关系。
5. 各 Agent Proxy 与 Accounts 注册、XConnect Gateway/One 联动、监控心跳和区域域名验证均随本区域步骤完成。TW/PH 只走 external-node job。每步成功后才进入下一步，最终摘要列出八项实际执行结果、资源 ID、state key 或 existing 引用、子流水线链接与前端入口检查。
6. Hybrid `plan` 检查所有上述声明和目前的 Cloudflare 复用契约，不调用 `apply`、业务部署或 DNS 更新；`deploy` 在所有输入和资源事实核对通过后才能扇出。每个子运行必须由可追踪的关联 ID 识别，避免并行的 Actions 运行被误认成自己的结果。
7. Hybrid 向两个子工作流传递同一个不可变发布版本、Git ref、环境、关联 ID 和路由配置。子工作流必须提供稳定的 `workflow_call` 输入/输出；Hybrid 只消费输出的主机清单、origin URL、部署状态和健康状态，不读取子工作流内部 job 名称。
8. Serverless 发布 Cloudflare Pages/Workers 后，将 Selfhost origin 和 Cloud Run origin 写入环境绑定或 Worker 配置；禁止把 origin、账号或区域硬编码在 Worker 源码。默认 `routing_mode=selfhost-first`，并允许以后显式选择 `cloud-run-first`、`selfhost-only` 或 `cloud-run-only`，但每次选择都必须出现在运行摘要中。

## Hybrid 流量调度契约

`selfhost-first` 的目标是把稳定流量留在已付费或低边际成本的 Selfhost 节点，仅在必要时使用 Cloud Run。落地时至少包含以下控制面：

- Selfhost 与 Cloud Run 分别提供不访问外部依赖的存活检查，以及验证数据库/关键依赖的就绪检查；Worker 只依据就绪状态执行回退。
- Worker 使用短时熔断状态、严格超时和有限重试。一次请求最多选择一个写入 origin，不能在响应不确定时把写请求重放到另一个 origin。
- 可按路径、请求方法、租户或发布比例覆盖路由；默认 SSR 与 API 都走 Selfhost，明确标记的异步、突发或隔离工作负载才走 Cloud Run。
- PostgreSQL 仍由 Selfhost API 负责访问。Supabase 的身份、存储、实时能力或副本职责与业务主库职责分开声明，不能仅因 Serverless 被调用就改变数据主从关系。
- Pages/Workers 发布失败不应回滚已成功创建的基础设施；Hybrid 停止后续步骤并给出可重试的子流程和关联 ID。
- 最终摘要输出 Pages deployment、Worker version、Selfhost origin、Cloud Run origin、实际 routing mode、健康状态和回退演练结果，但不输出凭据。

## 三个工作流的职责边界

| 工作流 | 负责 | 不负责 |
| --- | --- | --- |
| `hybrid-orchestrator.yml` | 对外 `workflow_dispatch`、读取 GitOps 发布矩阵、生成关联 ID、按依赖顺序调用子工作流、执行环境保护审批、汇总结果、验证最终路由 | Terraform 渲染、SSH、Playbook、容器部署、直接写 Vault、直接发布应用镜像 |
| `selfhost-orchestrator.yml` | provider registry 路由、Terraform 或 existing adapter、主机初始化、Selfhost API/PostgreSQL、Agent Proxy、Observability Agent、inventory/CMDB 输出 | Cloudflare Pages/Workers、Cloud Run、Supabase 发布和全局跨域编排 |
| `serverless-orchestrator.yml` | Supabase、Cloud Run、Cloudflare Pages/Workers、边缘路由配置和 Serverless 健康检查 | 创建 VPS、修改 Terraform state、SSH 到节点、接管 Selfhost PostgreSQL 生命周期 |

Hybrid 应通过 reusable workflow 的 `uses: ./.github/workflows/<name>.yml` 调用两个子工作流。两个子工作流保留独立 `workflow_dispatch` 供单域调试，同时增加稳定的 `workflow_call` 契约。Hybrid 不依赖子工作流内部 job 名称，只依赖版本化输入和输出。

## 顶层 dispatch 契约

Hybrid 的人工入口只暴露发布意图，不要求操作者手工拼装八项 provider 参数。provider、账号、区域、规格和资源身份从 GitOps 矩阵读取。

| 输入 | 默认值 | 规则 |
| --- | --- | --- |
| `operation` | `plan` | 第一阶段只支持 `plan`、`deploy`、`verify`；不提供 `target_domains=all + destroy` |
| `target_domains` | `all` | `all` 执行本文固定八项；单项值用于故障重试和开发验证 |
| `vault_env_path` | `uat` | 本方案只验收 UAT；非 UAT 必须使用另一份 GitOps profile 和审批环境 |
| `release_tag` | 无 | `deploy` 必填，传给两个子工作流且全程不可变 |
| `git_ref` | `main` | Toolkit、IaC、GitOps、Playbooks 和应用仓库的解析策略必须写入摘要 |
| `runner` | `ubuntu-latest` | 可选 self-hosted，但不能改变权限和状态范围 |
| `routing_mode` | `selfhost-first` | 可选 `selfhost-first`、`selfhost-only`、`cloud-run-first`、`cloud-run-only` |
| `cloud_run_fallback` | `safe-methods` | `safe-methods` 只允许 `GET/HEAD/OPTIONS` 自动回退；也可设为 `disabled` |
| `domain_suffix` | `onwalk.net` | 只决定本次 UAT 应用域名，不修改 provider 或 state 身份 |
| `observability_endpoint` | `https://observability.svc.plus` | 所有新建和 existing 节点必须使用同一显式端点 |
| `deploy_existing_nodes` | `true` | 只允许对 TW/PH 执行应用配置；永远不允许创建或销毁它们 |

Hybrid 在运行开始时生成 `execution_id=<run_id>-<run_attempt>`。所有子调用、CMDB 记录、Worker 版本元数据和最终摘要均携带该值，以便区分重跑和并发发布。

### Selfhost 子工作流接口

每次调用只处理一个业务域或区域，禁止再在子工作流内部把 `all` 展开为另一套隐式矩阵。

建议输入：`operation`、`environment`、`target_domain`、`provider`、`account`、`region`、`resource_profile`、`management_mode`、`release_tag`、`git_ref`、`execution_id`、`observability_endpoint`。

建议输出：

- `result`：`planned`、`deployed`、`verified` 或 `failed`。
- `resource_identity`：云资源 ID 或 existing CMDB identity。
- `state_key`：Terraform 项返回真实 key；existing 项为空。
- `inventory_ref`：S3 inventory/CMDB 引用，不直接输出 SSH 凭据。
- `origin_url`：仅 Web SaaS 返回可供 Worker 使用的 Selfhost API origin。
- `health_status`：主机、应用和 Observability Agent 的汇总状态。

### Serverless 子工作流接口

建议输入：`operation`、`environment`、`target_domain=web-saas`、`release_tag`、`git_ref`、`execution_id`、`domain_suffix`、`routing_mode`、`cloud_run_fallback`、`selfhost_origin`、`activate_edge`。

建议输出：

- `pages_deployment_id` 和预览 URL。
- `worker_version`，包括 frontend-router、SSR 和 edge-gateway 的版本集合。
- `cloud_run_origin` 和 revision。
- `supabase_status`，但不输出数据库连接串。
- `edge_status` 与当前生效的 `routing_mode`。

两个子工作流的失败输出必须保留已创建资源和可重试信息；不得为了让 Hybrid 看起来“原子化”而自动 destroy 基础设施。

## `target_domains=all` 执行 DAG

| 检查点 | Hybrid 动作 | 子工作流 | 成功输出/门禁 |
| --- | --- | --- | --- |
| P0 | 解析 GitOps、校验账号/规格/state/Vault 元数据、生成执行清单 | 无 | 八项清单完整；没有跨环境路径；`deploy` 有不可变 tag |
| P1 | 建立 `open-platform` | Selfhost | GCP 2C4G 资源、监控和平台服务健康；本阶段不迁移数据或切 DNS |
| P2 | 建立 JP/US/SG Terraform 资源 | Selfhost | AWS/GCP/Akamai 三个 2C2G 主机完成 Terraform readiness；应用 Playbook 暂不启动 |
| P3 | XConnect Zero 网络门禁 | `xconnect-zero-cloud` | 使用 `tw-xconnect.svc.plus` 完成 UAT Gateway/One 联动；失败则停止后续部署 |
| P4 | 部署 Web SaaS Serverless 面 | Serverless | Supabase、Cloud Run、Pages/Workers 发布成功；Worker 同时获得两个 origin |
| P5 | 验证 `selfhost-first` | Hybrid | 安全读请求主路径命中 Selfhost；受控故障下回退 Cloud Run；写请求不重放 |
| P6 | 部署 `ai-workspace` | Selfhost existing-host | XConnect 到 `10.79.0.7` 可达；不创建、不修改 Terraform state；AI Workspace 与监控心跳正常 |
| P7 | 部署 JP/US/SG Agent Proxy 应用 | Selfhost | Gateway/Proxy-Server/CPA 与 Accounts 心跳通过 |
| P8 | 配置 `agent-proxy-tw`、`agent-proxy-ph` | Selfhost existing adapter | 无 Terraform 变更；三角色、Caddy、心跳与监控通过 |
| P9 | 汇总和全链路验证 | Hybrid | 八项结果、origin、state/CMDB 引用、路由版本和失败恢复入口齐全 |

P0 到 P9 串行门禁。失败后 Hybrid 停在当前检查点；重跑时根据同一个资源 identity 和 state key 做幂等 plan，不重新创建已成功资源。单项重试必须引用原始 `execution_id` 作为 parent，并在最终摘要中显示替代关系。

## GitOps 非敏感声明契约

GitOps 是资源意图和流量策略的唯一人工入口。建议以一份 UAT Hybrid profile 表达八项资源；下例只定义字段结构，不代表未确认的账号或实例类型已经获批：

```yaml
environment: uat
project: svc.plus
release:
  target_domains: all
  routing_mode: selfhost-first
  cloud_run_fallback: safe-methods
  frontend: cloudflare-pages-workers
resources:
  - namespace: open-platform
    provider: akamai-cloud
    management_mode: terraform
    account: manbuzhe2026
    profile: 2C4G
  - namespace: web-saas
    provider: gcp-cloud
    management_mode: existing
    account: <confirmed-gcp-project>
    resource_ref: <confirmed-vault-node-0-identity>
    profile: 2C4G
  - namespace: ai-workspace
    provider: gcp-cloud
    management_mode: existing-selfhost
    account: <confirmed-gcp-project>
    existing_host: 10.79.0.7
    xconnect_required: true
    profile: 4C8G
  - namespace: agent-proxy-jp
    provider: aws-cloud
    management_mode: terraform
    account: <confirmed-aws-account-id>
    profile: 2C2G
  - namespace: agent-proxy-us
    provider: gcp-cloud
    management_mode: terraform
    account: <confirmed-gcp-project>
    profile: 2C2G
  - namespace: agent-proxy-sg
    provider: akamai-cloud
    management_mode: terraform
    account: manbuzhe2026
    profile: 2C2G
  - namespace: agent-proxy-tw
    provider: ulighthost
    management_mode: existing
    resource_ref: tw-xconnect.svc.plus
  - namespace: agent-proxy-ph
    provider: ulighthost
    management_mode: existing
    resource_ref: ph-xconnect.svc.plus
```

声明中禁止出现 token、密码、私钥、数据库连接串或临时 origin 凭据。`account` 必须是真实账户名/ID，不使用 `primary` 一类账号别名。renderer 负责将 `profile` 解析为 provider 的实际实例类型，并在 plan 摘要中同时展示抽象规格和实际型号。

## State、existing 与销毁边界

Terraform 资源继续遵循五级层次：

```text
terraform/<env>/<project>/<provider>/<account>/<workspace>/terraform.tfstate
```

本计划中的 `workspace` 等于 namespace。每个 Terraform 项只能看到自己的 state 和 `.tflock`；不能通过一个共享 `selfhost` state 管理多云八项资源。Web SaaS 复用节点、TW 和 PH 必须输出 external inventory，而不是创建空 Terraform state。

保护规则：

- Hybrid 不提供 `target_domains=all + destroy`。销毁必须从 Selfhost 对单一 Terraform namespace 发起，并经过环境审批。
- `management_mode=existing` 的资源拒绝 `apply`、`destroy`、import 和规格调整。
- shared Vault node、旧 Observability 节点以及外部 TW/PH 节点不进入本次 UAT state。
- `open-platform` 默认视为长期资源；即使未来允许销毁，也必须独立审批并先完成数据备份和服务迁出。
- state key、实际账号、资源 ID 和 GitOps namespace 不一致时立即失败，不尝试自动修复或 `state rm`。

## Worker 路由决策表

| 请求类型 | 默认 origin | 自动回退 | 说明 |
| --- | --- | --- | --- |
| 静态资源 | Cloudflare Pages | 无 | 使用不可变资源和缓存，不经过业务 origin |
| SSR 页面读取 | Selfhost SSR/API | Cloud Run | 仅在超时、连接失败或明确不可用时回退 |
| `GET/HEAD/OPTIONS` API | Selfhost API | Cloud Run | 要求同版本 API 和兼容读取模型 |
| `POST/PUT/PATCH/DELETE` | Selfhost API | 默认禁止 | 不因超时自动重放；客户端必须使用幂等键处理显式重试 |
| 明确标记的突发/异步路径 | Cloud Run | 按路径配置 | 仅适用于无共享本地状态或已设计异步队列的工作负载 |
| 健康检查 | 各 origin 独立端点 | 无 | 存活和就绪分开，不能用公开首页代替 |

Worker 配置至少包含 `SELFHOST_ORIGIN`、`CLOUD_RUN_ORIGIN`、`ROUTING_MODE`、`FALLBACK_POLICY`、origin 超时、熔断窗口和发布版本。非敏感值来自 GitOps/部署输出；敏感绑定由 Serverless 子工作流通过 Vault OIDC 获取。Worker 日志必须记录选择的 origin、回退原因、耗时、状态码和 `execution_id`，但不得记录 Authorization、Cookie 或请求正文。

## 凭据与权限模型

- Hybrid 自身只需要读取仓库和请求 GitHub OIDC 的最小权限；它不读取 provider token 或 SSH 私钥。
- Selfhost 子工作流按当前业务项登录对应 Vault JWT role，并只读取 `kv/data/CICD/uat/iac_state`、该 provider/账号凭据和目标主机连接事实。
- Serverless 子工作流只读取 UAT Supabase、GCP 和 Cloudflare 路径；Cloudflare Worker 不获得 Terraform state 或主机 SSH 凭据。
- GitHub environment `uat` 承担 deploy 审批和并发保护；`plan` 不访问写权限凭据。
- 子工作流不能提升调用者 permissions。所需 `id-token: write` 和 provider 权限必须在契约测试中显式验证。

## 失败、恢复与回滚

1. 基础设施或主机初始化失败：保留 state 和已创建资源，输出失败 namespace；修复后从该项重新 plan/apply。
2. Selfhost 应用失败：保留主机及上一版本容器，回滚应用 tag，不 destroy 资源。
3. Cloud Run 或 Supabase 失败：不激活新的 Worker 路由；Selfhost origin 保持独立可验收。
4. Pages/Worker 发布失败：回滚到上一 Worker version 和 Pages deployment；不回滚 VPS、数据库或 Agent Proxy。
5. Selfhost origin 运行期异常：Worker 只按方法策略回退；写流量保持单写并报警。
6. Agent Proxy 某区域失败：停止后续区域，已经成功的区域保持运行；修复后单区域重试，再执行 P9 全链路验证。
7. 复用的 AI Workspace 主机不可达：重新执行 existing-selfhost Playbook；QMD/持久数据不得仅存在于主机本地盘。

所有回滚都以“恢复上一可用应用或边缘版本”为主，不以销毁云资源作为默认回滚手段。

## Observability、成本与发布证据

- 所有 Selfhost 和 existing 节点默认安装 Observability Agent，并验证接入 `https://observability.svc.plus`；仅安装成功不算验收，必须看到带 namespace/provider/region 标签的心跳。
- Pages、Workers、Cloud Run 和 Selfhost API 使用同一个 release tag 与 `execution_id`，以便跨边缘和 origin 追踪请求。
- 为 Worker 输出 Selfhost 命中率、Cloud Run 回退率、回退原因、P50/P95/P99、5xx 和写请求拒绝回退数。
- 为 Cloud Run 设置按环境的请求量/费用告警；当回退率持续超阈值时报警，而不是永久静默把流量留在 Cloud Run。
- 最终摘要附加各云资源型号、生命周期、估算成本类别和实际路由分布，不在日志中打印任何 Vault secret。

## 测试与演练矩阵

| 层级 | 必测内容 |
| --- | --- |
| 静态契约 | YAML/schema、八项顺序、真实账号格式、state key、existing 禁止动作、workflow_call 输入/输出 |
| `plan` | 不申请写凭据、不创建资源、不改 DNS；展示八项 provider/规格/state 或 CMDB 引用 |
| 子工作流 | 每个 provider 单 namespace plan；TW/PH 只走 existing adapter；重复执行保持幂等 |
| 路由单测 | `selfhost-first`、四种 routing mode、安全方法回退、写请求不重放、超时和熔断 |
| UAT 故障注入 | Selfhost 读接口不可用时回退 Cloud Run；写接口不可用时明确失败；恢复后流量回主路径 |
| 数据契约 | PostgreSQL 单写、Supabase 职责、schema/version 兼容、备份恢复和幂等键 |
| 观测性 | 六个新建/复用业务节点和 TW/PH 心跳、Worker/Cloud Run trace 关联、日志脱敏 |
| 安全 | UAT role 无法读取 prod；existing 无 destroy；Worker 无数据库管理员凭据；输出无 secret |
| 恢复 | 从 P1-P8 任一点失败后单项重跑；Worker/Pages 回滚；Spot 节点重建；最终 P9 通过 |

## 分阶段实施工作包

1. **契约与 GitOps**：提交 Hybrid profile schema、八项资源声明、routing policy 和 renderer/validator；只做 dry-run。
2. **Reusable workflows**：为 Selfhost/Serverless 增加 `workflow_call` 输入输出，保留现有手工入口；增加契约测试。
3. **Selfhost 多云路由**：按单项调用 Akamai、AWS、GCP 和 existing adapter，补齐目标规格与独立 state。
4. **Serverless 边缘路由**：实现 Pages/Workers 发布、双 origin 绑定、`selfhost-first` 策略及安全方法回退测试。
5. **Hybrid DAG**：实现 P0-P9 串行调用、关联 ID、环境审批、失败停止、单项恢复和统一摘要。
6. **UAT 演练**：先 `plan`，再按 P1-P8 部署，完成路由故障注入和 P9 验收；未通过前不推广到 PROD。

每个工作包使用独立 PR；PR 合并只发布代码契约，不自动触发真实 UAT `deploy`。真实部署必须由 Hybrid 的人工 dispatch 和 UAT environment 审批启动。

## 现状差距与落地顺序

当前 `.github/workflows/hybrid-orchestrator.yml` 只验证 Serverless/Hybrid 边界并更新三个 edge-gateway Workers；它不调用 Selfhost 或 Serverless。Selfhost 的 `all` 固定扇出六个 Akamai namespace；GCP/AWS 的单地区 Agent Proxy 不受这个路由支持。Serverless 目前独立负责 Supabase、Cloud Run、Pages、Workers。这些都需要修改后才能声明混合矩阵已可部署。

- `open-platform` 的 UAT 目标已调整为 GCP `asia-east1` / 2C4G；实际 state、服务所有权和旧节点迁移边界仍需只读验收。
- `web-saas` 的 GCP `vault-node-0` 仍是共享 existing 事实；编排只调用 Serverless 和应用部署，不导入或修改该节点的 Terraform state。
- `ai-workspace` 复用 `10.79.0.7`，规格事实为 4C8G；它是 existing-selfhost 目标，不创建或修改 Terraform state，也不允许 destroy。执行前必须使用可访问 XConnect 私网的 runner，并确认 Vault 中的部署 SSH 凭据。
- Provider 选择由 `config/iac_provider_registry.json` 和矩阵行决定。AWS、GCP、Azure、Vultr、Akamai、UCloud 可作为 Terraform provider；非 IaC 创建好的主机使用 `existing` 或 `existing-selfhost`，不因矩阵 `all` 自动接管其生命周期。
- AWS UAT JP 现有声明默认 `t4g.micro`（2C1G）且没有单独 `agent-proxy-jp` state；目标 2C2G 可评估 `t4g.small`，并确认 ARM 版 Gateway/Proxy-Server/CPA 镜像、现有实例是否已被其他 state 管理。[AWS T4g 规格](https://aws.amazon.com/ec2/instance-types/t4/)。
- GCP US 的现有 `agent-proxy-us-workload.yaml` 是 `e2-micro` Spot、最长一小时；需确定 2C2G 实例类型、是否继续 Spot、目标账号和网络/SSH 可达性。
- Akamai SG 的现有 `agent-proxy-sg.yaml` 是 `g6-standard-1`（1C2G）。目标 2C2G 需通过 Linode types API 与 `sg-sin-2` 容量查询选择真实可用 plan；在型号确定前不提交假定规格。已销毁的旧 SG state 不能视为现有主机。[Akamai 计划文档](https://techdocs.akamai.com/cloud-computing/docs/how-to-choose-a-compute-instance-plan)。
- TW/PH 已有 Ulighthost external 声明和 Vault 凭据路径；需读回 CMDB/Vault 中的实例 ID、SSH 连接、Caddy 入口和三角色运行状态。不能因为 `all` 中包含两项而触发 Terraform。
- 现有 Hybrid GitOps 契约规定 Selfhost PostgreSQL 单写、Supabase 副本且只对安全方法做 Cloud Run failover。若希望 Supabase 改作 Web SaaS 主库，应先更新数据流、迁移与回滚设计及契约测试，再改入口。当前计划保持该契约，直到业务决定变更。

进入编码前必须关闭以下决策门禁：

1. 确认“Vault node 0”的真实 GCP project、实例 ID、当前 state owner、规格和是否允许承载 UAT Web SaaS；现有 `vault-prod-0 / e2-highcpu-2` 不能自动视为目标 2C4G。
2. 确认 Web SaaS 数据权威仍为 Selfhost PostgreSQL，并书面定义 Supabase 在 UAT 的身份、存储、实时或副本职责。
3. 确认 `10.79.0.7` 的 4C8G 规格、XConnect 可达性、磁盘持久化和 QMD 恢复目标。
4. 确认 AWS JP、GCP US、Akamai SG 的真实账号、区域、实际 2C2G 型号和独立 state key。
5. 确认 Cloudflare Pages project、Worker route 和现有 serverless 边界继续复用，不创建重复 DNS/Worker 名称。
6. 确认 TW/PH Vault 路径和 CMDB identity 为 UAT 记录，并验证 `management_mode=existing` 保护规则。

实施顺序：先补齐 GitOps 资源身份与规格声明；再扩展各 provider 的单 namespace IaC/复用 adapter、Selfhost 地区路由和三角色 playbook；随后让 Hybrid 按上表顺序调度 Selfhost/Serverless，并记录子运行 ID；最后做 `plan`、逐项 UAT 验收、Cloudflare 入口及回滚演练。未完成这些差距前，`deploy` 应显式失败并指出缺项。Selfhost 与 Serverless 保持可单独运行，Hybrid 只负责统一入口、依赖顺序和结果汇总。

## 验收标准

- `plan` 展示八项顺序、provider、账号、区域、规格、创建或复用身份、state key/CMDB 引用，且零资源变更。
- 每个 Terraform namespace 独立锁定和 `plan 0 add / 0 change / 0 destroy`；复用的 Vault、AI Workspace、TW、PH 节点没有 UAT 新 state。
- Web SaaS Selfhost 与 Serverless 的健康检查、Cloudflare Pages 静态资源、Workers API 路由、Supabase 数据关系均符合更新后的单写者契约。
- JP/US/SG/TW/PH 的 Gateway、Proxy-Server、CPA 各自健康，Accounts 心跳与 Observability Agent 正常；某一区域失败时后续步骤不启动。
- 最终摘要能追溯八项子流水线；反复部署不会重建现有资源或扩大 Terraform destroy 范围。
