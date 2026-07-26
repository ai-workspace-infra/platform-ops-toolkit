# 任务 4 详细规划：CI 子代理调试 + 四域 compose 补全 + UAT 端到端跑通

这是一份给后续接手者的任务记录。目标不是“再写一份概念说明”，而是把三条
相互依赖的链路拆成可重复执行、可验证、可回填的步骤：

1. 用 5 个子代理分别盯住 5 个业务仓的 CI 调试
2. 补全 `gitops/compose` 里四个业务域的部署结构
3. 跑通从 IaC 到验证的 `doco-cd` UAT 链路，直到 DNS 生效

> 这份记录强调“稳定迭代”而不是“一次性跑通”。如果中间任一层只靠人工猜测，
> 后面的 Doco-CD / DNS 只会把不稳定放大成“看起来成功”的假绿。

---

## 0. 当前前提

### 已确认的事实

- `docs/domains/DELIVERY-MANIFEST.md` 已明确四个业务域边界。
- `web-saas` 是目前最完整的参考形态，且它的交付模型与 Doco-CD 兼容。
- `platform-ops-toolkit` 只负责 IaC、编排、委派和环境资料，不直接构建业务镜像。
- 业务仓的构建、tag 契约与 GHCR 发布，属于各自 CI 责任。
- `gitops/compose` 的迁移不能靠“照着 web-saas 复制一份”蒙过去，必须逐域确认依赖。

### 本次要避免的错误

- 把“域”误当成“服务清单”直接复制。
- 在 compose 里臆造数据库或 stunnel 组件。
- 把 build、deploy、DNS 三个问题混成一个大任务一次性修。
- 让子代理只做搜索，不产出可验收结论。

---

## 1. 任务总目标

### 目标 A：CI Debugging with Subagents

为下列 5 个仓库分别建立独立调查视角：

- `accounts`
- `billing-service`
- `portal`
- `docs`
- `postgresql`

每个子代理只负责一个仓库，输出统一格式的诊断结果：

- 当前 CI 流程
- 失败或不稳定的根因
- 与 tag / 镜像 / Vault / workflow gating 的关系
- 建议修复点
- 可直接执行的验收命令

### 目标 B：补全 `gitops/compose` 的四个业务域

按 `DELIVERY-MANIFEST.md` 对齐四域：

- `web-saas`
- `ai-workspace`
- `agent-proxy`
- `open-platform`

要求每个域的 compose 结构都能说明：

- 哪些服务属于该域
- 哪些服务需要 `postgresql`
- 哪些服务需要 `stunnel-server`
- 哪些服务需要 `stunnel-client`
- 哪些基础组件是该域共享的

### 目标 C：跑通 UAT 的 IaC → Doco-CD → DNS

完成一次可复现的 UAT 路径，验证点包括：

- IaC 变更能正确落到主机侧资料
- Doco-CD 能从 `gitops` 仓收敛到目标 commit
- `web-saas` 套件能在 UAT 主机上启动
- DNS 切换后解析生效

---

## 1.1 现状差异表

### CI 子代理当前状态

| 仓库 | 现状 | 主要观察 |
|---|---|---|
| `accounts` | 已找到独立 CI workflow，部署逻辑已收敛到 GitOps / 镜像发布模型 | 本地验证 flags：PR 不推镜像，`main` 推 UAT + `latest`，`v*` tag 走 PROD 且不推 `latest`。主要风险转为镜像命名空间与 GitOps 消费端是否一致 |
| `portal` | 已找到独立前端 pipeline，构建与 runtime 配置分离 | 本地验证 inputs：PR=`sit`，`main`=`uat`，`release/*`/tag=`prod`。主要风险是 workflow 触发路径、生产域名 build args、镜像命名空间与 GitOps 是否一致 |
| `billing-service` | 待查 | 需要确认是否仍保留部署假设，或已完全转成纯 CI |
| `docs` | 待查 | 需要确认构建输入是否仍依赖未追踪内容 |
| `postgresql` | 待查 | 需要确认镜像、初始化脚本和健康检查是否稳定 |

### `accounts` 逐仓诊断结论

结论一句话：`accounts` 的 CI 已基本收敛到“构建并推送镜像”，但它能否被 GitOps 消费取决于 `IMAGE_REPO_OWNER` 是否显式设为 `x-evor`。

| 检查项 | 结论 | 验证方式 |
|---|---|---|
| PR 行为 | `deploy_env=sit`，`push_image=false`，不会推镜像 | 本地执行 `resolve-pipeline-flags.sh`，设置 `GITHUB_EVENT_NAME=pull_request` |
| main 行为 | `deploy_env=uat`，`push_image=true`，`push_latest=true` | 本地执行 `resolve-pipeline-flags.sh`，设置 `GITHUB_REF=refs/heads/main` |
| tag 行为 | `deploy_env=prod`，`push_image=true`，`push_latest=false` | 本地执行 `resolve-pipeline-flags.sh`，设置 `GITHUB_REF=refs/tags/v1.2.3` |
| tag 契约 | 使用 `docker/metadata-action` 的 `type=ref,event=tag`、`release/*`、`latest`、`sha,format=long` | 对齐 `IMAGE-TAG-CONTRACT.md` 的推荐实现 |
| GitOps 消费 | GitOps 期望 `ghcr.io/x-evor/accounts` | `gitops/services/accounts/base/values.yaml` |
| 主要风险 | 仓库 remote 是 `ai-workspace-services/accounts`，workflow 默认 owner 是 `github.repository_owner`。如果没有仓库变量覆盖，会推到 `ghcr.io/ai-workspace-services/accounts`，GitOps 拉 `ghcr.io/x-evor/accounts` 会落空 | 检查 GitHub repo variable `IMAGE_REPO_OWNER` 是否等于 `x-evor` |

需要保留：

- 当前 `prep` / `build` 两段结构。
- PR 不推镜像、`main` 推 `latest`、release/tag 不覆盖 `latest` 的语义。
- `docker/metadata-action` 的 `sha,format=long`。

建议最小修复：

- 若 GitHub 变量未配置，给 `accounts` 仓配置 `IMAGE_REPO_OWNER=x-evor`，或把 workflow 的默认值改成 GitOps 消费端同一个 namespace。
- 增加一个 CI 级自检：把最终 `steps.service_image.outputs.repo` 与 GitOps 期望仓库名比对，避免“推成功但 CD 拉不到”。

### `portal` 逐仓诊断结论

结论一句话：`portal` 的环境解析脚本能稳定区分 SIT / UAT / PROD，但镜像 namespace、workflow path filter 和生产域名 build args 仍是可验证风险。

| 检查项 | 结论 | 验证方式 |
|---|---|---|
| PR 行为 | `deployment_environment=sit` | 本地执行 `resolve-workflow-inputs.sh`，设置 `EVENT_NAME=pull_request` |
| main 行为 | `deployment_environment=uat`，`push_latest=true` | 本地执行 `resolve-workflow-inputs.sh` + `resolve-push-latest.sh` |
| release/tag 行为 | `deployment_environment=prod`，不推 `latest` | 本地执行 `resolve-workflow-inputs.sh` |
| sha tag | 默认产出 `sha-<40位>` | 本地执行 `compute-frontend-release-metadata.sh` |
| GitOps 消费 | GitOps 期望 `ghcr.io/x-evor/console` | `gitops/services/console/base/values.yaml` |
| 主要风险 1 | 仓库 remote 是 `ai-workspace-services/portal`，metadata 脚本固定使用 `GITHUB_REPOSITORY_OWNER`，会默认推到 `ghcr.io/ai-workspace-services/console` | `compute-frontend-release-metadata.sh` |
| 主要风险 2 | workflow 的 path filter 仍包含旧路径 `.github/workflows/pipeline.yaml`，当前文件是 `.github/workflows/ci-pipeline.yml` | 修改 workflow 本身可能不会触发 push CI |
| 主要风险 3 | workflow 顶层仍有 `console.xworkmate.com`、`NEXT_PUBLIC_RUNTIME_ENVIRONMENT=prod` 等生产值；build job 覆盖了环境名，但域名类 build args 仍会进入镜像 | 需要按 SIT/UAT/PROD 明确 build-time public URL 策略 |

需要保留：

- `resolve-workflow-inputs.sh` 中“CI 只构建镜像，部署由 GitOps 完成”的边界。
- Dockerfile 中不再硬编码运行时 `RUNTIME_ENV=prod` 的修复。
- `sha-<40位>` 的 release metadata。

建议最小修复：

- 让 `compute-frontend-release-metadata.sh` 支持显式 `GHCR_NAMESPACE` 或 `IMAGE_REPO_OWNER`，并在 workflow 中设为 `x-evor`。
- 把 path filter 里的 `.github/workflows/pipeline.yaml` 改成 `.github/workflows/ci-pipeline.yml`。
- 把生产域名 build args 从 workflow 顶层移出，按 `deployment_environment` 生成，或由 GitOps 运行时注入。

### `gitops` 当前状态

`gitops` 现在并不是一个传统意义上的 `compose/` 仓，而是按服务域拆成了 `services/`：

| 目录 | 现状 | 对四域补全的意义 |
|---|---|---|
| `services/accounts` | 已有 base / pre / prod 配置 | 是 web-saas 里最接近“可迁移服务”的一组输入 |
| `services/console` | 已有 base / pre / prod 配置 | 可以用来推断前端入口、Ingress 和镜像发布的结构 |
| `services/database/postgresql` | 已有数据库 + stunnel 相关资源 | 是后续补四域数据库层的直接参考 |
| `services/stunnel-client` | 已有独立 stunnel-client 资源 | 可以作为各域共享隧道能力的模板 |
| `services/database/stunnel-server` | 已有独立 stunnel-server 资源 | 可以作为各域数据库出口的模板 |
| `services/observability` / `services/platform` | 已有平台组件 | 说明这个仓库当前是“服务资源集合”，不是“按域 compose 目录” |

这意味着后续要补的不是“补一个缺失目录”，而是明确：

1. 哪些服务归属到四个业务域
2. 哪些服务需要从 `services/` 级别收敛成域级交付单元
3. 哪些数据库和 stunnel 组件应当复用现有模板，哪些必须按域复制

### 四域差异表：基于 `gitops/services`

| 业务域 | Manifest 服务 | GitOps 已有模板 | 缺口 | 下一步 |
|---|---|---|---|---|
| `web-saas` | Console、Accounts、Billing、Caddy、PostgreSQL | `services/console`、`services/accounts`、`services/database/postgresql`、`services/stunnel-client`、`services/database/stunnel-server` | 没有 `billing` 服务模板；没有域级封装把 console/accounts/billing/postgresql/stunnel/caddy 作为一个 web-saas 交付单元；GitOps 镜像 namespace/tag 与服务仓 CI 仍需统一 | 先补 `billing` 模板，再定义 `web-saas` 域级 kustomization 或 compose 等价入口 |
| `ai-workspace` | LiteLLM、OpenClaw、QMD、Agent/Model routing | 未发现域内服务模板；`console` 只引用了 `openclaw-gateway.svc.plus` 作为外部服务 | 缺 LiteLLM / OpenClaw / QMD / gateway 模板；缺域级数据库与 stunnel 判定；当前 docs 显示部分服务仍偏 Ansible/rootless 安装 | 先确认哪些服务已有镜像，再决定是否进入 GitOps/Doco-CD |
| `agent-proxy` | Caddy、Xray、Exporter、Vector、agent-svc-plus | `services/observability` 有 Vector / exporter 类观测模板，但未发现 agent-proxy 域模板 | 缺 Xray、agent-svc-plus、域内 Caddy 配置；未确认是否需要数据库/stunnel | 先从 playbooks 反查实际运行方式，再决定容器化边界 |
| `open-platform` | Gitea、Vault、Zitadel、Grafana、VictoriaMetrics 等 | `services/observability/observability-stack` 已有 Grafana、VictoriaMetrics / Logs / Traces；`services/platform/cert-manager` 和 `postgresql-tls` 已有平台支撑 | 缺 Gitea、Vault、Zitadel 域模板；Grafana/VictoriaMetrics 目前归在 observability，不是 open-platform 域级封装；Vault 是否纳入 GitOps 仍需架构确认 | 先把 observability 与 open-platform 的边界写清，再单独评估 Zitadel/Gitea/Vault |

### 跨域共性风险

- GitOps 目前消费 `ghcr.io/x-evor/*`，服务仓默认多为 `ai-workspace-services/*` owner；这必须用变量或脚本统一。
- GitOps 的 `prod` overlay 目前对 `accounts` / `console` 写的是 `tag: release`，但镜像契约要求 PROD 消费 `v*` tag 或 `release-*`，需要确认由哪个 CD 步骤把它改成真实 `deploy_tag`。
- `pre` / `prod` 已经存在，但 `DELIVERY-MANIFEST.md` 的环境语义是 SIT / UAT / PROD；需要明确 `pre` 是否等价 SIT、UAT，还是旧命名。
- PostgreSQL / stunnel 模板已经有了，但不能机械复制给所有域。每个域要先确认真实数据库依赖，再决定是否按域复制。

---

## 2. 推荐推进顺序

### 第一阶段：先收敛 CI 观察面

先让 5 个仓库的 CI 调试结果统一输出，否则后面的 compose 与 Doco-CD 只能拿到不完整的输入。

### 第二阶段：再补 compose 结构

只有在知道每个域真实依赖之后，才决定是否补 `postgresql` 和 `stunnel`。

### 第三阶段：最后接 UAT 端到端

当 compose 结构明确后，UAT 的部署链路才有稳定输入，否则验证会卡在“镜像对了但服务没法起”。

---

## 3. 子代理分工

### 子代理 1：`accounts`

关注点：

- CI 是否只保留 build / push 镜像
- workflow gating 是否还残留 deploy 逻辑
- tag 是否符合跨仓契约
- 是否已经支持 UAT / latest 流向

### 子代理 2：`billing-service`

关注点：

- 是否存在与 database 相关的 CI 假设
- 构建产物是否能被 GitOps 消费
- 是否有 Vault / secret 绑定问题

### 子代理 3：`portal`

关注点：

- 前端生成链路是否依赖 checkout 外内容
- 是否存在环境变量或 runtime env 漏洞
- 是否会在 CI 产出能被 Doco-CD 消费的镜像 tag

### 子代理 4：`docs`

关注点：

- 文档站是否存在构建输入缺失
- 是否仍有 `gitignore` / 生成器输入目录错配
- 是否有“本地能过、CI 才失败”的结构性问题

### 子代理 5：`postgresql`

关注点：

- 数据库镜像与初始化逻辑是否稳定
- 是否能作为各域 compose 的基础依赖
- 是否存在版本、权限、健康检查的隐性风险

### 子代理统一输出格式

每个子代理都必须输出以下条目：

1. 结论一句话
2. 当前阻塞点
3. 需要保留的工作流
4. 需要删除或收敛的工作流
5. 建议的最小修复
6. 验收命令

---

## 4. 四域 compose 补全规划

### 4.1 Web-saas

目标：

- 把现有参考形态补完整
- 让 web-saas 成为其他域的可复用模板，而不是特例

待确认：

- `accounts` / `billing` 是否需要独立 `postgresql`
- `stunnel-client` / `stunnel-server` 是否必须在 compose 内显式存在
- 现有资产目录是否已经满足 Doco-CD 绝对路径要求

### 4.2 AI-workspace

目标：

- 先确认真实服务归属，再决定 compose 颗粒度

待确认：

- `LiteLLM` 是否存在现实部署输入
- `OpenClaw` / `gateway` 是否需要容器化
- 哪些服务必须继续保留 Ansible 安装

### 4.3 Agent-proxy

目标：

- 先确认代理链和 exporter 的实际运行方式
- 再判断是否引入独立数据库和 stunnel 组

待确认：

- `agent-svc-plus` 是否已经有镜像化路径
- `Xray` / `Exporter` 是否只是主机服务
- 是否有跨域共享配置可抽出

### 4.4 Open-platform

目标：

- 以 `Zitadel`、`Grafana` 作为优先切入点
- 对 Vault、VictoriaMetrics 保持审慎，先确认现状再动手

待确认：

- Vault 是否迁移进 compose
- VictoriaMetrics 的真实部署方式
- 哪些组件属于域内必须保留的主机级服务

---

## 5. UAT 端到端执行规划

### 阶段 1：IaC 准备

确认：

- 环境参数
- 主机资源规格
- Vault OIDC 上下文
- `gitops` 仓的目标分支与 commit

### 阶段 2：主机初始化

确认：

- Docker / compose runtime 可用
- `/etc/xcontrol/<domain>/` 资料完整
- `.env.<env>` 与实际部署镜像一致

### 阶段 3：Doco-CD 收敛

确认：

- 仓库变更被 Doco-CD 正确拉取
- `deploy_tag` 与环境语义一致
- 容器健康检查不只是“起了”，而是“可用”

### 阶段 4：DNS 发布

确认：

- 记录切换前后解析一致
- TTL、缓存和生效时间被记录
- 切换后服务仍保持健康

---

## 6. 验收标准

### CI 子代理验收

- 5 个仓库都要有独立结论
- 每个结论都能落到一个最小修复动作
- 每个修复动作都能给出重跑方法

### compose 验收

- `gitops/compose/<domain>/` 结构完整
- compose 文件能在目标环境变量下通过配置检查
- 不存在“凭空发明的数据库或隧道”

### UAT 验收

- IaC 执行成功
- Doco-CD 完成收敛
- web-saas 套件可启动
- DNS 解析正确生效

---

## 7. 记录策略

后续调试过程中，建议把每一轮结果都按下面格式回填到 `docs/tasks/`：

- `发现了什么`
- `是在哪一层发现的`
- `为什么之前没暴露`
- `最终修复是什么`
- `怎样复现`

这样可以把“调试过程”变成可复用资产，而不是一次性聊天记录。

---

## 8. 本轮建议的下一步

1. 先给 5 个子代理下发统一模板，收集仓库级结论。
2. 同步确认 `gitops/compose` 中四个域的现状与缺口。
3. 再把 UAT 链路拆成 IaC、Doco-CD、DNS 三段分别验收。
