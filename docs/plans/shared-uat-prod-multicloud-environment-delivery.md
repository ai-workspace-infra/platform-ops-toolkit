# Shared / UAT / PROD 多云环境与发布链路规划

日期：2026-09-30。状态：规划与控制面契约；未执行资源变更或发布。

本文整理最新目标、代码核查结果及实施验收项，不是新的运行时 matrix。资源声明仍以经审批的 GitOps commit 为准；本文中的目标表不能代替 GitOps。已有本地 workflow 修改不视为已合并实现。

关联历史任务：[Epic #838](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/838)、[资源建设 #845](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/845)、[部署与迁移 #846](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/846)。#838 仍描述旧六 Akamai namespace，实施前须补充或拆出新任务，并关联本规划；不能将历史验收标准当作当前多云目标。

本轮实现范围包含环境文档、Daily Snapshot 只读 Shared readiness gate 及其契约测试；不执行 Terraform `plan/apply/destroy`、state import/removal、Org Policy 写入、DNS 切换、数据迁移或 GitHub workflow dispatch。

## 1. 工程规范与职责边界

采用 [engineering-standards](https://github.com/ai-workspace-lab/xworkspace-core-skills/tree/26463ee076784d2c6ab39d3c86da5373406b880d/skills/engineering-standards) 的 GitOps 唯一声明、IaC/配置解耦、不可变发布、防假绿和需求溯源规则。该规范部分 repository map 保留旧实现描述，例如 Vultr-only；本规划以实际代码核查为准，不复制过时的运行时路由。

| 层 | 权威来源 / 仓库 | 负责 | 禁止 |
| --- | --- | --- | --- |
| 需求 | Issue / 审批记录 | 目标、范围、验收与授权 | 用旧 Issue 静默覆盖新要求 |
| 非敏感期望配置 | `gitops` | provider、账户引用、项目、区域、规格、生命周期、allowlist、服务依赖 | 秘密值、生成 inventory、第二套环境 matrix |
| 敏感信息 | Vault KV / 动态 secrets | provider 凭据、SSH 材料、服务凭据 | 放进 GitOps、文档、公开日志或 dispatch inputs |
| IaC | `iac_modules` | provider adapter、renderer、backend、云资源、运行时输出 | 软件部署、数据迁移、手写主机清单 |
| 配置交付 | `playbooks` / 专用服务仓库 | SSH 初始化、Caddy、运行时、服务及监控探针、显式迁移 | 接管 Terraform 资源或维护第二套拓扑 |
| 编排 | `platform-ops-toolkit` | OIDC、审批、调用、依赖门禁、证据汇总 | 复制 provider 模块或应用构建实现 |
| 制品 | CI / `artifacts` | 镜像、包、digest、来源证明 | 将重新构建的 `main` 冒充已验收版本 |

发生规范、历史文档与新需求冲突时，记录差异并更新任务；不在本轮擅自调整环境、权限或资源。

## 2. 环境与项目身份

| 范围 | 平台域名空间 | GCP 实际项目 ID | 发布入口 / 边界 |
| --- | --- | --- | --- |
| Shared | `svc.plus` | `open-platform-shared-510113` | 独立 Open Platform 生命周期，不属于 Hybrid 业务 matrix |
| UAT | `onwalk.net` | `open-platform-uat` | Daily Snapshot → UAT Hybrid → Selfhost / Serverless |
| PROD | `svc.plus` | `open-platform-prod` | 成功 UAT 的不可变制品晋级 → 生产审批 → PROD Hybrid |

`open-platform-shared` 是显示名/现有账户配置标识，不是 GCP 实际项目 ID。声明中的 `project_id`、WIF 目标 service account 和云 API 查询必须明确指向 `open-platform-shared-510113`。

GitOps 路径的逻辑项目、state 的 `state_project`、provider 的账户标识、GCP `project_id` 是不同字段，不能从域名或显示名猜测。现有 `xworktech`、`open-platform-shared` 账户引用必须经受控配置解析为可核验的云身份，不应声称它们就是实际项目 ID。多账号逐行解析，不能由 workflow 的全局 provider/account 覆盖。

`xworktech.com` 仅作为主页/组织标识，不是新平台资源路径或域名的缺省值。现有 `resources/svc.plus/uat/**` 需要逐项迁移审查，不能仅重命名路径而改变既有 backend identity。

受保护的 `open-platform-prod/vault-prod-0` 独立保留：专用 Vault 主节点和 `net_security_vault` Gateway，不被 UAT Web SaaS 复用，不导入业务 state，不改名、不销毁。

## 3. Shared：三个独立 state，独立服务生命周期

| Namespace | GitOps manifest（当前 main） | 实例 | 目标职责 |
| --- | --- | --- | --- |
| `open-platform-shared-vault` | `resources/svc.plus/shared/gcp/open-platform-shared-vault.yaml` | `vault-shared-0` | Vault；保留旧源节点，迁移另行审批 |
| `open-platform-shared-observability` | `resources/svc.plus/shared/gcp/open-platform-shared-observability.yaml` | `observability-shared-0` | Observability；验证历史数据与 Grafana 面板保留 |
| `open-platform-shared-iam` | `resources/svc.plus/shared/gcp/open-platform-shared-iam.yaml` | `iam-shared-0` | IAM / ZITADEL |

三份声明当前均指向 `open-platform-shared-510113 / asia-east1 / asia-east1-a`，请求公网 IP。Vault 当前机器类型为 `e2-highcpu-2`；Observability/IAM 为 `e2-medium`。抽象 CPU/内存标签不是云规格能力证明，应核对 shared-core / dedicated、实际内存及可用容量。

每个 state key 独立：

```text
terraform/shared/open-platform-shared-510113/gcp-cloud/open-platform-shared/open-platform-shared-vault/terraform.tfstate
terraform/shared/open-platform-shared-510113/gcp-cloud/open-platform-shared/open-platform-shared-observability/terraform.tfstate
terraform/shared/open-platform-shared-510113/gcp-cloud/open-platform-shared/open-platform-shared-iam/terraform.tfstate
```

以上为已核对的声明 key，不表示本轮已验证远端 state 或实例存在。三个 state 各自锁定，资源输出不能互相充当成功证据。

独立 `open-platform-orchestrator.yml` 负责经授权的资源申请、部署、升级、迁移；调用 `vault-server.yml`、`observability-server.yml` 及 IAM 对应交付入口。普通业务发布只消费就绪服务，不调用这些服务的部署入口。

当前 shared 声明 `xconnect_mode=member / role=one`，加入 `net_security_vault: 10.79.0.0/24`；受保护旧 Vault 节点仍是 Gateway。不得把新 shared Vault 当成第二个 Gateway，也不得把共享安全网当作 UAT 默认业务网。

## 4. 最新业务目标矩阵（尚待落实到 GitOps）

`open-platform-shared` 从下表彻底排除。Hybrid `all` 只展开该环境经审批的业务声明，逐行选择 provider，而不是把 `all` 套进一朵云。

### 4.1 UAT

| 顺序 | Namespace | 管理模式 | Provider | 规格 / 生命周期 |
| --- | --- | --- | --- | --- |
| 1 | `web-saas` | 持久主机 + Serverless | GCP | 独立业务主机；允许 stop/start，禁止 destroy；规格显式声明 |
| 2 | `ai-workspace` | Existing Selfhost | GCP/private | 默认复用 GitOps 声明的现有主机；不创建 Terraform VM；如需新建必须显式开启独立 IaC 流程 |
| 3 | `agent-proxy-jp` | Terraform | AWS Spot | 2C2G，租约最长 3600 秒 |
| 4 | `agent-proxy-us` | Terraform | GCP Spot | 2C2G，最长运行 3600 秒 |
| 5 | `agent-proxy-sg` | Terraform | GCP Spot | 2C2G，最长运行 3600 秒 |

UAT TW/PH 是否继续参加 `all`，应在新 GitOps matrix 中显式决定；最新 UAT 清单未列出它们，不默认追加。若声明加入，仍走 existing adapter，不纳入 Terraform state。

### 4.2 PROD

| 顺序 | Namespace | 管理模式 | Provider | 规格 / 生命周期 |
| --- | --- | --- | --- | --- |
| 1 | `web-saas` | 持久主机 + Serverless | GCP | 独立业务主机；允许 stop/start，禁止 destroy |
| 2 | `ai-workspace` | Existing Selfhost | GCP/private | 默认复用 GitOps 声明的现有主机；不创建 Terraform VM；如需新建必须显式开启独立 IaC 流程 |
| 3 | `agent-proxy-jp` | Terraform | AWS | 2C2G，持久，禁止 destroy |
| 4 | `agent-proxy-us` | Terraform | GCP | 2C2G，持久，禁止 destroy |
| 5 | `agent-proxy-sg` | Terraform | Akamai Cloud | 2C2G，持久，禁止 destroy |
| 6 | `agent-proxy-tw` | existing | Ulighthost | 复用，不进入 Terraform state |
| 7 | `agent-proxy-ph` | existing | Ulighthost | 复用，不进入 Terraform state |

这是默认分布，不是 provider 白名单硬编码：变更区域、账户或 provider 必须通过 GitOps PR 和兼容性预检；涉及现有资源身份改变时，先制定迁移方案，不能直接改旧 state 的 provider。

Web SaaS 前端为 Cloudflare Pages + Workers（SSR / edge gateway）。默认 Selfhost-first 后端 API + PostgreSQL；Cloud Run 为经声明的回退/分流目标，Supabase 按已批准的数据职责使用。Worker 不直接持有 PostgreSQL 管理凭据；写请求不得在未经幂等与单写者验收时自动跨后端重试。

Spot“1 小时”是运行上限/租约，不保证运行满一小时。GCP 当前模块终止动作是 `STOP`；停止不等于删除，磁盘和其他资源仍需独立核算。AWS 的 1h 必须有可验证的租约/停止或清理机制，不能仅依赖 Spot 回收。本轮没有自动 destroy 授权。QMD 等记忆数据须脱离临时根盘并验证恢复。

## 5. 多云 IaC renderer：统一契约，provider-specific adapter

```text
GitOps 固定 commit 的环境资源矩阵
  → 校验 environment / project / account / namespace / management_mode
  → provider registry（每行解析，不覆盖具体 provider）
      ├─ terraform → provider renderer → 独立 workdir / backend / plan
      └─ existing  → 外部资源事实校验 → inventory / CMDB（不执行 Terraform）
  → 统一 CMDB → 动态 inventory → Playbooks domain CD
```

| Registry provider | GitOps 目录 alias | 当前 IaC tree / renderer | 模式与公网能力核查 |
| --- | --- | --- | --- |
| `aws-cloud` | `aws` | `terraform-hcl-standard/aws-cloud/scripts/generate.py` | Terraform；VPC/subnet 路由、公网地址、SG、实例 identity |
| `gcp-cloud` | `gcp` | `terraform-hcl-standard/gcp-cloud/scripts/generate.py` | Terraform；GCP Org Policy、access_config、firewall、OS Login |
| `akamai-cloud` | `akamai` | `terraform-hcl-standard/akamai-cloud/scripts/generate.py` | Terraform / `linode/linode`；真实账户、区域规格、公网地址、firewall |
| `vultr-vps` | `vultr` | `terraform-hcl-standard/vultr-vps/scripts/generate.py` | Terraform；plan/region、IP、firewall、可原地变配方向 |
| `ucloud` | `ucloud` | `terraform-hcl-standard/ucloud/scripts/generate.py` | Terraform / UHost；bootstrap key-pair/SG 输出、VPC/subnet、EIP 关联与容量 |
| `ulighthost` | `ulighthost` | 无 Terraform tree | existing-only；Vault 主机事实及归属校验 |

当前 registry 另列 `azure-cloud`，作为扩展 adapter 保留；本轮重点为上述五朵云。存在模块/registry 不等于该云已经完成此次发布验收。

尤其不能沿用“UCloud 一律不支持 Terraform”的旧假设：当前 main 有 UHost 模块；Ulighthost 与 UHost 必须分开。即使 provider 支持 Terraform，显式 existing 声明也不能被自动转换为 create/import/apply。

Renderer 统一要求：

1. 显式接收 `--resources` 和 `--workdir`，记录输入 GitOps SHA；无声明即失败，不退回生产目录。
2. 将不同 YAML dialect 规范化为同一身份对象，验证 namespace 唯一和顺序。
3. 用 Python/Jinja 展开显式资源块，模块只表达 provider 资源能力，不承载环境拓扑。
4. 保持资源名与 state 一一对应；域名、运行 tag 变化不得引发非预期 VM 重建。
5. 明确 persistent/spot/existing，不把持久主机送进默认 Spot 模块。
6. 公网能力、删除保护与期限是 provider 能力，不虚构跨云等价字段；不支持时失败或明确列出限制。
7. `render` 不读取 provider 私钥、无云写入；`inventory` 合并声明与当次 Terraform 输出，不能使用陈旧 IP。
8. 派生 HCL、tfvars、inventory 不签入仓库；plan/state 敏感内容不得作为公开 artifact。

状态契约：

```text
terraform/<env>/<state-project>/<provider>/<resolved-account>/<namespace>/terraform.tfstate
terraform/<env>/<state-project>/<provider>/<resolved-account>/<namespace>/terraform.tfstate.tflock
```

`state-project` 是经过校验的逻辑 state 项目，实际 GCP 项目另用 `project_id`。所有 adapter 和 workflow 必须使用同一计算规则。当前 GCP renderer 支持 `spec.state_project`，但 reusable workflow 仍按 `project_id` 校验 key，必须先统一，不能用搬动 S3 key 掩盖契约冲突。

S3-compatible backend 参数入口保持 `kv/data/CICD/<env>/iac_state` 的 `TF_STATE_*`（bucket、region、endpoint 与所需认证字段）。保持 endpoint，不强制改为只支持 AWS 原生端点；验证目标对象存储支持所用锁机制、Versioning 和加密。backend 凭据与云资源 provider 凭据分离，运行时注入，禁止静态写入 HCL/tfvars。

## 6. 六段公网 VM 交付链路与证据

```text
GitOps allowlist / 网络意图
  ↓
多云 IaC renderer
  ↓
Provider policy / 网络约束（GCP 为 Org Policy）
  ↓
Terraform VM public_ip / 网络与防火墙
  ↓
CMDB / inventory
  ↓
Playbook SSH、Caddy、Observability / XConnect 验证
```

| 检查点 | 输入与责任层 | 必须保存的证据 | 失败时停止的位置 |
| --- | --- | --- | --- |
| GitOps allowlist | 精确 project/zone/instance；GitOps | commit SHA、解析后的名单、资源唯一性 | 渲染前 |
| IaC renderer | provider schema、模式、backend identity；IaC | renderer SHA、生成 plan 的配置身份、key/lock 范围 | init/apply 前 |
| GCP Org Policy | `compute.vmExternalIpAccess`；管理员 seed 或唯一 owner state | 目标 project 的 effective allowedValues 与声明对比 | VM apply 前 |
| VM 公网与网络 | provider 输出、firewall、SSH 授权；IaC | 项目/zone/实例 ID、状态、公私网 IP、实际公网配置 | inventory/SSH 前 |
| CMDB/inventory | 当次输出 + 非敏感静态字段；IaC/adapter | 主机数、instance ID、目标组、resolved ansible_host | Playbook 前 |
| 配置与服务 | CMDB + Vault；Playbooks | 实际匹配主机、SSH/sudo、Caddy/TLS、探针入库和心跳 | 发布汇总前 |

### GCP policy 所有权

`manage_external_ip_policy=false` 表示管理员 bootstrap 已写入策略，日常 WIF 仅读取核验，renderer 不生成策略资源；不能在这一模式下声称此次 Terraform “已 apply Org Policy”。Shared Vault 声明当前就是此模式，注释中的“owns policy”不能当作 state ownership 证据。

若改由 Terraform 管理，项目级同一个 constraint 只允许一个 owner state；先核对精确 policy ID、备份现有 spec、检查 state 是否已有 owner，再经独立审批导入。其他 namespace 只消费，不各自创建相同策略。业务部署账号不因查询失败获得全组织 policyAdmin。

公网验收须同时验证有效 allowlist、VM access_config/EIP、公网路由、firewall 和 SSH 授权；仅 `public_ip: true` 或 Terraform 退出 0 不充分。Shared 与 UAT 名单不得混用；拒绝测试不能放行未声明的实例。

### CMDB 与配置层

统一主机记录应包含 environment、provider、实际 account/project、namespace、instance ID、public/private IP、ansible_user、groups、声明 SHA 和生成时间；existing 记录带外部身份/来源而非伪造 Terraform address。

当前 GCP CMDB 是含项目 metadata、`vault_nodes` 和部分顶层 host 记录的混合结构，而动态 inventory 逐项按 host 字典消费。必须在交接层规范化或明确采用专用消费入口，不能直接把全部 JSON 键当成 SSH 主机。

生成动态 inventory 后核对目标数量不为零、实例 ID 与云侧一致，再检查 SSH/sudo。Caddy 配置先 validate 再 reload，域名从当前环境声明解析，TLS 和边界 HTTPS 均验证。监控探针默认开启，但必须验证此节点在配置的 Observability 网关收到新时间戳指标/日志；服务 `active` 不等于监控已入库。

XConnect 验收区分控制面 ACK、指定 peer handshake、私网 ping/HTTP 标记。Gateway、网段、One/controller 地址由 GitOps 解析，不能在 workflow 中硬编码 TW/PH。节点停止/租约结束后，连接授权的撤销是单独生命周期事项。

## 7. Daily Snapshot：只检查 Shared 就绪，再发业务版本

目标入口：[daily-main-snapshot.yaml](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/workflows/daily-main-snapshot.yaml)。

```text
解析各仓 SHA → 创建不可变 daily tag → 验证所有必需构建/制品
  → Vault readiness
  → Observability readiness
  → IAM readiness
  → dispatch UAT Hybrid（固定 GitOps SHA / tag / correlation ID）
  → 等待 Selfhost + Serverless + 后端/前端/监控验收全部通过
  → 留存 UAT evidence
  → 显式晋级同一制品为正式 release（生产审批）
  → PROD Hybrid → 等待完整发布结果
```

Daily 的 `Vault → Observability → IAM` 是串行只读检查，不是三个基础设施 apply job。某服务不可用时停止并链接独立平台工作流，不能自动安装、升级、初始化、unseal、重启、恢复、迁移或切换 DNS。构建可以并行，但业务 dispatch 必须依赖全部就绪门禁成功。

| 服务 | 只读就绪标准（目标） | 边界 |
| --- | --- | --- |
| Vault | TLS 正常；`/v1/sys/health` 及允许的 standby 状态符合契约；initialized=true、sealed=false；必要时独立 OIDC 最小只读探针 | 不初始化/unseal，不导出 KV，不向部署账号暴露管理员 token |
| Observability | 配置入口 health；Grafana database=ok；配置要求的 metrics/logs/traces 接口健康 | Daily 不执行数据恢复；新探针入库由业务部署验收补充 |
| IAM | 配置 issuer 的 OIDC discovery 与健康端点正常、issuer 匹配；必要时受限客户端检查 | 最终 readiness 路径需按当前 ZITADEL role 确认，不以登录页 HTTP 200 代替 |

探针 URL、允许状态码、超时与证书要求放入 GitOps shared dependency 声明；只读认证从 Vault 获取。UAT 显式消费 Shared 服务是已批准依赖，不是缺参后退回 PROD。缺少声明或输出不得跳过检查并继续发布。

普通 `all/deploy` 只部署，不自动迁移数据。迁移只由显式 operation、任务范围和审批启用。Serverless 发布 Cloudflare 入口前必须完成所要求的后端健康门禁。

生产晋级必须校验 UAT run 的实际成功结论、tag 对应的各仓 commit 和全部制品 digest、GitOps 声明及回滚点。生产应用制品与 UAT 验收制品相同，不从移动的 `main` 重建。稳定 tag 不覆盖、不删除；标记 tag 不能冒充镜像/包晋级。

Daily 控制面可以从 `main` 创建 release，但 PROD 子工作流必须在符合生产 ref allowlist 的受保护入口执行；dispatch 的 `env=prod` 不能让 `main` 直接取得生产部署凭据。GitHub Environment 审批、Vault 精确 workflow/ref/environment 绑定与账户权限共同生效。

## 8. 当前代码与目标的差距

核查基线（不是实时部署结果）：

| 仓库 | 已核对的 revision | 核查范围 |
| --- | --- | --- |
| Toolkit | `1ec802018a96e55006e9428ee45669556cfb489a` | registry、Daily dispatch 脚本、Hybrid、GCP reusable pipeline、服务验证入口 |
| GitOps | `e505d9e020986c1ba4df8c6ece80bc17f8a596ef` | UAT matrix、UAT GCP manifest、三份 Shared manifest |
| IaC | `cd34be7a900e025c35fd587e84b78ea9555915ee` | renderer/template、GCP VM 模块、UCloud UHost、provider tree |
| Playbooks | `4c5187f0ae64d49b8cc0004f1e96b91f637fc3c4` | `inventory/terraform_cmdb.py` |

本轮未核验云侧实例、远端 state 或最新 Daily run 的完整绿色结论。

| ID | 核查发现 | 目标修正 / 风险 |
| --- | --- | --- |
| GAP-01 | 已修正：Daily Snapshot 不再暴露 `SHARED_PLATFORM_ACTION`，也不调用 Open Platform deploy | Shared 由独立 `open-platform-orchestrator.yml` 管理；Daily 只执行 Vault → Observability → IAM 只读 readiness |
| GAP-02 | GitOps UAT matrix 仍含 open-platform，SG 为 Akamai、业务项多为 ephemeral | 拆 Shared，落实最新 UAT/PROD 默认 provider 与生命周期；逐行固定身份 |
| GAP-03 | UAT web-saas 使用 `resources.spot_vms`，GCP 模块固定 SPOT | 建持久计算 adapter/声明，独立保护；先评估现有数据，不自动替换 |
| GAP-04 | GCP renderer 支持 state_project，pipeline key 校验只用 project_id | 统一 key 计算及测试；不得盲移 state |
| GAP-05 | GCP renderer/pipeline 仍有旧 xworktech.com 默认路径 | 使资源输入显式必填，缺失失败，无生产 fallback |
| GAP-06 | Hybrid 输入及若干读取路径仅支持 UAT | 在生产 ref/审批约束下支持 PROD GitOps，不能只增加一个 dropdown |
| GAP-07 | PROD dispatch 仍直接扇出 Serverless 和旧 AWS/Akamai Selfhost | 统一经 PROD Hybrid 消费 PROD matrix，保留后端/前端门禁 |
| GAP-08 | GCP duration 字段可选；AWS 1h 和持久保护未做本轮运行验证 | schema、plan 与租约机制分别验收，不能以标签代替保护 |
| GAP-09 | 动态 inventory 对缺失 CMDB 返回空对象，混合 metadata 结构未统一 | 严格转换、目标匹配/可达性 guard，零主机与缺 instance ID 必须失败 |
| GAP-10 | Observability 验证脚本仍写死生产服务域名 | 从依赖声明注入端点，分别核查 endpoint health 和实际数据流 |
| GAP-11 | 本地存在未合并的串行 shared jobs / promotion 草稿 | 不算已交付；按最新只读 Daily 边界审查，不能直接上线旧草稿 |
| GAP-12 | #838 仍为旧六 Akamai 规划 | 回写最新目标、受保护资源、跨仓任务和可证伪验收，再实现 |
| GAP-13 | 已修正：UAT→PROD 晋级只给 3 个 `production_promotion` 仓库建 `v*` tag，但 PROD Serverless 以 `v*` checkout `portal` / `frontend-router` | `promote-uat-snapshot-tag.sh` 覆盖规范组织全部清单仓库，先全量校验再创建；由 `daily_snapshot_promote_uat_tag_test.sh` 覆盖 |
| GAP-14 | 已修正：`production` 审批挂在整个汇总 job，先于 UAT 部署 | 晋级拆为独立 `promote-prod` job，须 UAT Hybrid 步骤 `success`（`skipped` 不算）后才审批，并在派发前重新做只读 Shared readiness |
| GAP-15 | 已修正：Hybrid 无法承载 `enable_migration`、schema 迁移、基线采纳、XConnect release 覆盖，Daily 校验后静默丢弃 | UAT 派发前明确失败；转发能力需扩展 Hybrid → 子流水线的输入并经真实 UAT 演练验证，尚未实现 |
| GAP-16 | 契约已实现、PROD 未执行：UAT Serverless 记录每个 Cloud Run 镜像 digest 与源码 commit（`serverless-artifact-manifest`），经 Hybrid（`uat-artifact-manifest`）与 Daily（`uat-promotion-manifest`）校验后转交 PROD；PROD 不再从 `v*` 源码构建，按 digest 复制并核对正在服务的 revision digest；UAT failure/pending、digest 不符、main→prod 均拒绝（`prod_same_digest_promotion_test.sh`） | 首次真实 PROD 晋级前需审批：PROD 部署 SA 读取 UAT `serverless` Artifact Registry 的跨项目只读权限；Daily `deploy_env=prod` 不再打 tag 或从源码构建，只能经 `uat_daily_run_id` 晋级已验收的 UAT run（见 §13.3）。Selfhost/Agent Proxy 仍按 tag 部署，PROD Hybrid（GAP-06/07）未完成 |
| GAP-17 | 已修正控制面：Daily PROD dispatch 使用 `dns_mode=none`，不再隐式接管 canonical DNS | 单独 DNS 切换工作流、审批和真实回滚演练仍需独立验收；此项不代表 PROD Hybrid 或同 digest 晋级完成 |

## 9. 小步实施计划与合并顺序

| 阶段 | 交付范围 | 完成标准 |
| --- | --- | --- |
| P0 规划 | 本文 + 需求任务对齐 | 最新矩阵、Shared/业务边界及禁止操作明确，未知项列出 |
| P1 GitOps | UAT/PROD matrix、依赖 readiness、lifecycle/租约、精确 allowlist | schema 和快照测试通过，无 secrets；路径变化不隐式换 backend |
| P2 IaC | 多云 adapter 契约、持久/Spot 分离、state 与 CMDB | 五云 render 正/负用例通过，Terraform validate，existing 零 Terraform 操作 |
| P3 Playbooks | CMDB 动态 inventory、配置/探针/XConnect 验收 | syntax-check、非空目标 guard、配置幂等与健康检查 |
| P4 Toolkit | Daily 只读门禁、轻量 Hybrid、生产晋级 | mock dispatch 合约证明无 Shared 部署，无 PROD 绕过，无跳过假绿 |
| P5 UAT 演练 | 再获执行授权后 plan → 审批 apply/deploy | 云侧/输出/主机/数据流/父子 run 证据齐全，后续 plan 0/0/0 |
| P6 PROD | 同制品晋级、独立审批及发布 | PROD ref/OIDC/GitOps 一致；持久资源零删除，完整回滚路径 |

## 10. 本轮 Daily Snapshot 落地边界

本轮代码变更已将 Daily Snapshot 与 Shared 平台写操作解耦：

1. `snapshot-summary` 在完整快照成功后，依次执行只读的 Vault、Observability、IAM readiness 探针。
2. 三个探针任意失败时，不 dispatch UAT Hybrid，也不执行 PROD 发布；失败结果必须保留在 workflow 日志中。
3. UAT Hybrid 仍使用不可变 `daily-build-*` 制品并以 `target_domains=all / operation=deploy` 发布业务矩阵；普通发布不触发迁移或 destroy。
4. 只有 UAT Hybrid 成功后，且显式开启生产晋级并通过 production Environment 审批，才把同一制品转换为 `v*` release tag 并进入 PROD 发布入口。
5. Shared 的 Terraform、服务部署、升级和迁移仍通过独立 `open-platform-orchestrator.yml` 触发；Daily Snapshot 不创建、更新、销毁或迁移 Shared 资源。

验证命令：

```text
bash .github/scripts/tests/shared_readiness_probe_test.sh
bash .github/scripts/tests/daily_snapshot_uat_gate_contract_test.sh
bash .github/scripts/tests/daily_snapshot_combined_dispatch_test.sh
bash .github/scripts/tests/daily_snapshot_promote_uat_tag_test.sh
```

这些是本地契约/模拟验证，不等同于真实云侧 `apply`、DNS 切换或业务发布成功；真实发布仍需在合并后的 `main` 上以 GitHub Actions run 作为证据。

先建立任务溯源和跨仓兼容窗口。兼容变更按依赖顺序合并：声明/schema → IaC → Playbooks → Toolkit；若新声明依赖尚不可用的模块，可先合并兼容支持，再启用声明，不能把消费者上线到缺失契约。

每仓独立 PR、测试与 merge SHA，均回指父任务；代码合并不证明部署成功。本轮仅提交控制面契约与验证代码，不触发真实 Terraform、DNS、迁移或销毁。

## 10. 回归用例与发布完成定义

| 用例 | 方法 | 通过条件 |
| --- | --- | --- |
| TC-01 多云路由 | 对五云声明执行离线 render / registry 测试 | namespace/provider/account/workdir 精确匹配，无全局 provider 覆盖 |
| TC-02 existing | existing / Ulighthost mock invocation | 不调用 Terraform init/apply/import/destroy，仅校验外部事实 |
| TC-03 key/锁 | 比较每层 backend key；受控并发锁测试另行执行 | 五级身份一致，各 namespace 隔离，同 key 第二作业被锁阻止 |
| TC-04 policy | GCP effective policy 只读对比 | 所需公网实例均在精确名单；禁止实例不能获得放行 |
| TC-05 云侧资源 | apply 后按 project/zone/name 读取 API | 实例真实存在、状态符合目标、公网 IP 与 Terraform 输出一致 |
| TC-06 CMDB | 动态 inventory 列表与云侧 ID 对比 | 主机数/组/地址一致；混合 metadata、空输出、旧 IP 均失败 |
| TC-07 配置 | 精确 inventory ping/sudo、Playbook syntax 与配置验证 | 目标不为空，Caddy reload 前配置通过，HTTPS/TLS 正常 |
| TC-08 监控/网络 | 查新 node 指标时间戳、日志；指定 peer/私网 HTTP | 监控接收和 XConnect 数据面均有证据，非仅 active/ACK |
| TC-09 Daily 只读 | mock workflow dispatcher / 权限负例 | Vault→Observability→IAM 顺序；任一失败无 Hybrid dispatch；无平台写调用 |
| TC-10 版本晋级 | UAT failure/pending、digest mismatch、main→prod 负例 | 全部被拒绝；成功 UAT 同制品才可经审批晋级 |
| TC-11 生命周期 | plan JSON 与 owner/租约检查 | persistent 无 delete/replace；Spot duration/租约有效；保护名单排除销毁 |
| TC-12 发布闭环 | 汇总父子 run、制品/声明 SHA 与业务健康 | 必需项全 success，unknown/skipped 不冒充验收通过，保留回滚版本 |

只读运维核查示例（后续操作人注入目标，不含秘密值）：

```bash
: "${GCP_PROJECT_ID:?selected GitOps project_id is required}"
gcloud resource-manager org-policies describe \
  constraints/compute.vmExternalIpAccess \
  --project="$GCP_PROJECT_ID" --effective
gcloud compute instances list --project="$GCP_PROJECT_ID" \
  --format='table(name,zone.basename(),status,machineType.basename(),networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)'
```

健康、库存与日志只收集脱敏证据，文档引用 Vault path/字段名，不记录秘密值。由于实例生命周期可变化，上述代码快照不能代替执行时的新鲜 API 输出。

验收记录至少含：任务/PR、各仓 SHA、tag/digest、GitOps manifest、environment/provider/account/project、state key、实例 ID、inventory artifact、readiness 与服务/数据流结果、父子 run URL、时间、失败/回滚结果。

下一步应先确认 P0 文档与目标矩阵，补充当前任务，再从 P1/P2 合约测试推进；不能依据本文直接宣称 Daily 已可顺利发布 UAT/PROD。

## 11. 源码与历史文档

- [Toolkit registry](https://github.com/ai-workspace-infra/platform-ops-toolkit/blob/1ec802018a96e55006e9428ee45669556cfb489a/config/iac_provider_registry.json)、[UAT dispatch](https://github.com/ai-workspace-infra/platform-ops-toolkit/blob/1ec802018a96e55006e9428ee45669556cfb489a/.github/scripts/snapshots/dispatch-uat-combined.sh)、[Hybrid](https://github.com/ai-workspace-infra/platform-ops-toolkit/blob/1ec802018a96e55006e9428ee45669556cfb489a/.github/workflows/hybrid-orchestrator.yml)、[GCP pipeline](https://github.com/ai-workspace-infra/platform-ops-toolkit/blob/1ec802018a96e55006e9428ee45669556cfb489a/.github/workflows/gcp-iac-pipeline.yml)。
- [GitOps UAT matrix](https://github.com/ai-workspace-infra/gitops/blob/e505d9e020986c1ba4df8c6ece80bc17f8a596ef/topology/uat/hybrid/resource-matrix.json)、[Shared 声明目录](https://github.com/ai-workspace-infra/gitops/tree/e505d9e020986c1ba4df8c6ece80bc17f8a596ef/resources/svc.plus/shared/gcp)。
- [IaC GCP renderer](https://github.com/ai-workspace-infra/iac_modules/blob/cd34be7a900e025c35fd587e84b78ea9555915ee/terraform-hcl-standard/gcp-cloud/scripts/generate.py)、[UCloud UHost 模块说明](https://github.com/ai-workspace-infra/iac_modules/blob/cd34be7a900e025c35fd587e84b78ea9555915ee/terraform-hcl-standard/ucloud/README.md)、[binding AGENTS](https://github.com/ai-workspace-infra/iac_modules/blob/cd34be7a900e025c35fd587e84b78ea9555915ee/terraform-hcl-standard/AGENTS.md)。
- [Playbooks inventory](https://github.com/ai-workspace-infra/playbooks/blob/4c5187f0ae64d49b8cc0004f1e96b91f637fc3c4/inventory/terraform_cmdb.py)。
- [Daily 手册](../daily-snapshot-manual.md)、[旧 UAT Hybrid 复用计划](hybrid-uat-multicloud-resource-reuse.md)：涉及平台自动部署、Vault node 复用、旧默认 provider 或晋级行为时，须结合本文差异审查，不能直接复用旧命令。

## 12. 补充：Shared / UAT / PROD 的 XConnect Gateway / One 网络规划

本节为追加规划，前述资源矩阵、生命周期、state、Daily 职责和受保护节点均保持不变。本轮不改 GitOps、不创建 Gateway、不重新注册设备、不写路由/ACL、不轮换凭据。表中的候选或待确认配置不代表线上已启用。

采用 `engineering-standards/zero-trust-overlay-delivery` 的所有权与验收规则：GitOps 声明网络意图，Zero/Accounts 管理授权、签名配置和租约，Gateway/One 实施数据面，Vault 提供敏感材料；ACK、握手、私网流量与监控接收分别验收。

### 12.1 重新规划的目标与既有声明

最新约束：Shared 现有 network ID 与 `10.79.0.0/24` 都保持不变。UAT/PROD 重新规划为两张独立网络，不改业务资源/provider 矩阵，不将 Shared Gateway 迁移或借给业务环境。

| 范围 | Network identity 规划 | Overlay CIDR 候选 | Gateway 规划 | 状态 |
| --- | --- | --- | --- | --- |
| Shared | 保留当前已注册的 network ID；不重命名、不新建替代网 | `10.79.0.0/24`（保持） | 受保护 `vault-prod-0` 保持 | 只记录现状与核对引用，不执行 ID/CIDR 迁移 |
| UAT | 新网逻辑标识建议 `net_uat_v2`，具体 controller ID 在审批后的创建输出中确认 | `10.250.10.0/24` | TW existing 为优先候选；不支持隔离新旧 runtime 时采用独立 UAT Gateway | 新规划，待 IPAM/路由复核和审批 |
| PROD | 新网逻辑标识建议 `net_prod_v2`，具体 controller ID 在审批后的创建输出中确认 | `10.250.20.0/24` | 独立持久 PROD Gateway，不复用 Shared/UAT Gateway | 新规划，待 IPAM/路由复核和审批 |

两张候选网络互不重叠，也不与 Shared overlay 重叠。选择新逻辑标识是为了不在旧 `net_uat`/`net_prod` 身份下直接替换 CIDR；它不是本轮已创建的 controller network ID。

曾考虑的 `10.81.0.0/24` 与仓库仍保留的 `resources/xworktech.com/shared/gcp/vault-shared.yaml` 中 `10.81.0.0/20` 重叠，故不作为本次新 PROD 方案。`10.240.0.0/16` 也被 global-mesh 声明使用，不能选其子段。新的 `10.250.*` 只是在已读取声明中避开已知冲突，不代表已证明所有云、办公 VPN、容器和外部路由都无冲突；全量 IPAM 与实际路由检查通过后才能保留它们。

地址意图统一采用下表，实际 `/32` 由 Zero/IPAM 分配；接口地址的掩码与路由根据 runtime 契约决定，不把整个地址池默认授权给每个 One：

| 用途 | UAT 候选地址 | PROD 候选地址 | 分配规则 |
| --- | --- | --- | --- |
| Gateway | `10.250.10.1` | `10.250.20.1` | 每网独占，保留于持久 Gateway |
| 网络设施预留 | `.2`–`.9` | `.2`–`.9` | 不自动配置 HA/DNS/代理，实际设施另行声明 |
| 持久业务 One | `.10`–`.63` | `.10`–`.63` | Web SaaS / 持久 Agent Proxy 等按 device identity 固定租约 |
| Spot / 临时 One | `.64`–`.199` | `.64`–`.199` | 动态租约，最长不超过批准的实例期限，回收后再复用 |
| 运维 One | `.200`–`.239` | `.200`–`.239` | 显式授权和审计，不继承 Shared 管理网权限 |
| 扩展预留 | `.240`–`.254` | `.240`–`.254` | 未声明即不可分配 |

地址池只是规划，不表示现有 Zero 已支持上述分池策略；实施前确认 allocator、保留地址和租约冲突检查能力。`.0`/`.255` 不分配给主机。

已读取的旧声明保留为现状台账，不能当作新目标：

| 网络范围 | Network ID / Overlay CIDR | Gateway 所有权 | One 接入对象 | 当前边界 |
| --- | --- | --- | --- | --- |
| `open-platform-shared` 安全管理网 | 文档/边界目录为 `net_security_vault / 10.79.0.0/24`；Shared One 声明为 `net_shared_vault / 10.79.0.0/24` | 保留受保护 `vault-prod-0`，不自动迁移到 `vault-shared-0` | Shared Vault、Observability、IAM，以及获批 DevSecOps 设备 | ID 尚不一致，不能创建两张相同 CIDR 的网或把两个 ID 当成已实现的 alias |
| UAT 业务网 | `net_uat / 10.77.0.0/24` | 复用 Ulighthost `tw-01`，当前 endpoint 引用 `tw-xconnect.svc.plus` | UAT Web SaaS、AI Workspace、JP/US/SG；其他 existing 节点仅在 UAT 声明显式启用后加入 | Gateway 是外部持久依赖，不进入业务 Terraform state；业务 Spot 只作 One |
| PROD 业务网 | One 声明为 `net_prod / 10.78.0.0/24`；边界目录候选为 `net_prod_dedicated / 10.81.0.0/24` | 规划专用 PROD Gateway，候选资源 `prod-xconnect-gateway-01` | PROD Web SaaS、AI Workspace、JP/US/SG、声明的 TW/PH existing | `pending-prod-gateway`；ID/CIDR、endpoint 和具体 provider 未统一，不能视为可部署 |

旧表中 Shared 的两个名称只作为引用差异记录；现有已注册 ID 保留，不借本次 UAT/PROD 重规划自动统一、重命名或重新 enrollment。旧 UAT/PROD CIDR、pending endpoint 也不自动删除或切换。新方案的 ID/CIDR/Gateway 最终写入 GitOps 后由消费者解析，不能复制为 workflow/playbook 默认值。

GCP VPC/subnet 与 XConnect overlay 是两层网络。Shared 当前 VPC 子网 `10.82.0.0/20`、`10.83.0.0/20`、`10.84.0.0/20` 不等于 Overlay `10.79.0.0/24`。实施时还须检查所有云 VPC、容器、办公 VPN 和已接入网络是否重叠，不能只比较上述三张网。

### 12.2 控制面、Gateway 与 One 分工

```text
Zero / Accounts（网络授权、设备身份、签名配置、租约）
  ├─ Shared 管理域 → 受保护 Vault Gateway → Shared One / DevSecOps One
  ├─ UAT 业务域    → TW existing Gateway → UAT 多云业务 One
  └─ PROD 业务域   → 专用 PROD Gateway   → PROD 多云业务 One

各业务网 → 经明确授权的 HTTPS / 服务入口 → Shared Vault / IAM / Observability
默认无 UAT ↔ PROD 路由，也无业务网 ↔ Shared 管理网整段路由
```

Zero 不传输 VPN 数据包；Gateway 不签发自己的 policy；One 不能自授路由或上传设备私钥。GitOps 只保存 network/device identity、角色、地址意图、transport profile、生命周期和秘密引用，不保存邀请、签名运行配置或完整 peer 文件。

Gateway 的云实例身份、overlay 地址、传输入口域名、Vault 服务域名和 controller URL 是不同字段。`vault.svc.plus` 是服务入口，不自动等于 Gateway transport host；Shared 声明还有 `vault-xconnect.svc.plus`。必须核验其解析、Caddy 路由和实际 Gateway 所在主机，不能根据某个域名猜 SSH 目标或迁移源。

### 12.3 Shared：保持 Gateway，补齐服务 One

1. `vault-prod-0` 继续承担 `net_security_vault` 的保护性 Gateway 职责；业务 workflow 不修改、改名、接管 state 或重新 enrollment。
2. 新 `vault-shared-0` 是 One，不是默认接班 Gateway。Gateway 迁移属于独立审批和回滚任务，本轮不实施。
3. Shared Vault、Observability、IAM 三个独立 Terraform state 的输出提供主机身份；分别将它们纳入 Shared One 清单，不因某模块名为 `vault_vm` 就推断角色为 Gateway。
4. 当前 Shared One 文件只显式列出 `vault-shared-0`；Observability/IAM 的资源声明已要求 role=one，但不等于 controller 已登记或隧道已连通。后续需要补齐设备声明、注册记录与验收证据。
5. 已声明 Gateway 地址为 `10.79.0.1`、Shared Vault One 为 `10.79.0.10`；这里只记录现有地址意图，新增 One 地址由统一 IPAM/Zero 分配，不直接给 IAM/Observability 猜一个尾号。
6. 运维 One 只拥有获批主机/端口的 SSH、DNS 或管理访问。普通 UAT/PROD 业务 One 不加入管理网，不自动获得 Vault 8200/8201、SSH 22 或管理 API 的访问权限。

三类共享服务可通过已批准的服务域名/私有服务入口提供给 UAT/PROD，授权按环境隔离。共享服务是共同依赖，不表示业务账号有共享平台部署权限或生产数据权限。

### 12.4 UAT：新网络、隔离 Gateway 与业务 One

UAT 新网候选为 `net_uat_v2 / 10.250.10.0/24`，Gateway 为独立持久依赖，不能随 Web SaaS/Spot 业务资源清理。TW 主机复用不等于允许覆盖其旧 Gateway：只有 runtime 支持独立身份、接口、state directory、端口与 systemd 单元时，才可规划同机新网；否则先申请独立 UAT Gateway，保留旧 TW 服务并在批准窗口切换。具体 provider/account/region/profile 与 transport endpoint 来自 GitOps，不在本节强制选云。

若新增 Terraform Gateway，建议独立 namespace `xconnect-gateway-uat`，不并入既有业务 `all` 资源 matrix；existing Gateway 保持 external ownership，无业务 Terraform state。普通 `all/deploy` 只消费审批后明确启用且已验收的网，不能自动创建新网、升级 TW 或尝试两个 CIDR 的 fallback。

| UAT 节点类 | XConnect 角色 | 接入与租约要求 |
| --- | --- | --- |
| GCP Web SaaS 持久主机 | One | 与实例身份关联的持久设备；stop/start 不删除设备，凭据按策略轮换 |
| GCP AI Workspace Spot | One | 单次实例/租约身份；租约不超过声明的运行期限，不超过 60 分钟 |
| AWS JP、GCP US/SG Spot | One | 每区域、实例、环境独立身份；不复用 PROD device ID/key |
| 声明显式启用的 external 节点 | One 或已审批的 Gateway | 主机复用不等于角色复用；不能给 TW Gateway 再重复配置同一网络的 One runtime |

先完成云资源、CMDB 和最小 bootstrap SSH，再加入 Zero、拉取并校验签名配置、启动 One；证明 Gateway peer、私网目标和部署所需依赖可达后，才执行依赖内网的业务步骤。overlay 加入之前不能要求它本身提供唯一 SSH 通路；无公网 bootstrap 时需要已验证的私网 runner/IAP 或其他声明方式。

Spot 正常到期、意外回收或重建时，由租约 reconcile 撤销旧 device/credential，Gateway 同步后去除旧 peer；不能只靠实例停止或 One systemd 退出判断授权已撤销。新实例使用新的注册过程；复用 overlay IP 前确认旧租约已释放。

### 12.5 PROD：独立持久 Gateway 与持久/Spot One

PROD 新网候选为 `net_prod_v2 / 10.250.20.0/24`。Gateway 不复用 Shared `vault-prod-0`，不默认复用 UAT TW Gateway，不能放在 1h Spot 生命周期内。其 provider/account/region/profile、public endpoint、SSH 与 transport allowlist 均需由 PROD GitOps 单独声明。

当前边界目录建议独立 namespace `xconnect-gateway-prod`。若后续选 Terraform，使用独立 key：

```text
terraform/prod/<state-project>/<provider>/<resolved-account>/xconnect-gateway-prod/terraform.tfstate
```

该 Gateway 不加入现有业务 `all` 资源矩阵；业务 Hybrid 只做就绪依赖核查。创建、升级、迁移、灾备以及获批删除通过独立网络生命周期任务执行。这个独立依赖方案只是新增规划，不表示本轮增加一个新 VM 或 state。

PROD Web SaaS、JP/US/SG 持久节点作为各自 One；PROD AI Workspace Spot 为有期限 One；TW/PH existing 若作为 PROD One，使用 PROD network/device identity 和凭据，不进入业务 Terraform state。

PROD One 旧声明目前仍有 `required-prod-gateway` 和指向 UAT TW 的 transport host，故不能解除 `blocked-by-prod-gateway`。须先在新规划网内完成独立 Gateway、Accounts 签名配置、Vault 精确路径和验收，再经审批切换到新 GitOps 引用；不能把旧网的阻塞标记直接删除后继续部署。

若同一物理 TW/PH 主机承载多环境或兼任角色，需要独立 device identity、接口、state directory、端口和 systemd 单元，并先验证 runtime 支持多网络；现有声明已提示单网络限制，不能只加域名就认为隔离成立。不在本轮把同一 Gateway 实例同时分配给 UAT/PROD。

### 12.6 跨网访问、DNS 与 transport

- 默认拒绝 UAT → PROD、PROD → UAT，以及业务网 → Shared 管理网的横向访问；不发布 `0.0.0.0/0` 或整段 `10.79.0.0/24` 的通配路由。
- 业务访问共享 Vault、IAM、Observability 时，以 workload identity、环境、服务端口和方法定义最小权限；优先使用显式 HTTPS 服务入口，私网方案需单独声明服务代理/受控路由及回程路径，不用全网互通替代服务授权。
- 网络放行不代替 Vault JWT/policy、IAM client/tenant 或监控写入凭据；UAT 不能通过共享入口读取 PROD KV/业务数据。
- Zero 签名 policy、Gateway 转发/防火墙和目标服务认证共同落实 ACL；WireGuard AllowedIPs/握手本身不是应用访问控制证据。
- 私有 DNS、split-horizon zone、resolver 与地址由每张网声明。相同服务域名不能在不同网络被解释成不同环境的 SSH 目标；公共 Caddy 入口和私有 DNS 分别测试，不把传输域名自动发布成服务切换。
- 当前 One 声明 transport 为 `vless-xhttp / TCP 443 / /xconnect`，UAT/Shared 使用 `caddy-unix-h2c`。验收应支持 Caddy → h2c/Unix socket 的实际入口，不能错误要求 Xray 直接监听公网 TLS 443。
- 上述 profile 必须从 GitOps 注入；公开 WireGuard UDP 入口保持关闭，除非另有批准的 transport profile。不得将 README 的端口/path/host 复制成脚本 fallback。

### 12.7 声明、秘密与 workflow 交接

| 内容 | 归属 / 当前入口 | 补充规则 |
| --- | --- | --- |
| 三网边界 | `gitops/topology/xconnect/network-boundaries.yaml` | 按网络保留唯一 ID/CIDR/Gateway 引用；当前冲突先记录，不自动合并 |
| One/transport 意图 | `gitops/vpn-overlay/{shared,uat,prod}/` | 当前为分层文件；后续由同一规范化对象派生消费者，避免双写漂移 |
| 云资源与 output | `iac_modules` + GitOps resource manifest | provider-neutral 身份与 CMDB；不渲染设备私钥或 peer secrets |
| 主机及服务配置 | Playbooks Gateway / One roles | 幂等安装与签名配置应用，不创建 controller 网络或代签 policy |
| 注册、授权及 lease | Zero / Accounts | 环境/租户/设备边界，短期注册凭据，撤销证据 |
| 编排与摘要 | Toolkit | 传同一个 GitOps SHA、network/device identity、artifact digest 与 correlation ID |

Shared One 文件当前引用敏感材料路径 `kv/data/CICD/shared/xconnect`。UAT/PROD 的 enrollment、controller service token、TLS/transport 及主机 SSH 引用应按环境和 network/device 精确拆分；最终路径/字段沿用现有受控 Vault 契约再补齐，不在本规划伪造已存在的 secret。

特别是当前 UAT boundary 的 Gateway/One 连接记录仍引用 `prod/ulighthost-xconnect/*`。这只是现状，不是批准 UAT role 读取 PROD 的依据；后续需核验同一外部主机的 owner、环境独立 credential 和最小只读引用，或提供批准的受限连接代理。不能为修复读取失败而给 UAT role 加生产通配权限，也不能自动把迁移源 `observability.svc.plus` 当作新 One 目标。

注册邀请、Bearer Token、VLESS 凭据、设备私钥不放到 GitOps、dispatch、artifact 或文档；设备私钥留在受保护的设备运行时存储，不上传给控制面。这里只记录路径引用与字段职责。

Daily 仍只检查 Shared Vault → Observability → IAM，不负责 Gateway 升级。Hybrid 业务阶段使用所选环境的 network readiness gate，再让 Selfhost 交付 One；Serverless/Cloudflare Worker/Cloud Run 不因同属一个 release 自动成为 One，私网访问能力必须有独立声明和网络集成。

### 12.8 网络验收与待办

| 用例 | 验收证据 / 必须失败的情况 |
| --- | --- |
| NET-01 身份与地址 | 每网唯一 network ID；CIDR 与 VPC/overlay 无重叠；Gateway 与 One 地址不冲突；不同环境设备身份不可串用 |
| NET-02 Gateway 保护 | 云/主机 identity 与声明一致；保护节点不进入业务变更范围；pending PROD Gateway 阻止注册与部署 |
| NET-03 One 注册 | 短期邀请/credential scope、正确 controller/network、签名 revision 与 ACK；错误环境和失效邀请被拒绝 |
| NET-04 真实数据面 | 精确期望 peer 的新握手、私网 ping 和 bounded HTTP marker；仅 ACK 或任意 peer handshake 不算通过 |
| NET-05 访问隔离 | 获批共享服务访问成功；UAT→PROD、未授权 SSH/Vault endpoint/其他租户访问被拒绝，区分网络与应用拒绝原因 |
| NET-06 租约撤销 | Spot 到期/意外回收后 controller 撤销、Gateway peer 删除、旧 credential 不可重用；不是仅云实例 STOP |
| NET-07 DNS / transport | resolver、TLS、声明的 XHTTP/Caddy 路由和目标服务一致；无静默退回生产域名/旧 SSH 地址 |
| NET-08 重跑与监控 | 同实例重跑不重复注册/抢占地址；stop/start 可恢复；node/network 标签监控新样本到达配置入口 |

实施前的最小待办：只读核对并保持 Shared 已注册 ID/网段；复核新 UAT/PROD 候选段与地址池；确认 TW 新旧 runtime 隔离能力或独立 UAT Gateway；声明独立 PROD Gateway；补齐 Shared Observability/IAM One；核对 UAT 的跨环境 Vault 记录；为持久/Spot/existing 分别定义注册和撤销。以上均先建或更新任务、PR 与验收标准，保持本轮现有配置不变。

新旧网切换另行执行，不改 Shared：

1. 只读盘点旧 UAT/PROD 的实际 network ID、peer、租约、ACL、DNS 和引用；记录哪些旧网只是声明、哪些已活跃。
2. 完成全量地址冲突和 runtime 能力检查，通过 GitOps PR 固定新网/Gateway/One 意图及 Vault 引用。
3. 经批准创建新网和隔离 Gateway；先用测试 One 验收签名配置、握手、ACL、DNS、共享服务访问及监控。
4. 分批把对应环境业务 One 纳入新网，更新明确的 active network 引用；每批保留上一配置和可回滚证据，不让客户端自动在新旧网间选择。
5. 不支持双网的设备在维护窗口切换并立即验收，失败则恢复旧注册/路由；不在同一单网 runtime 中覆盖两个 peer 集合。
6. 观察期通过后，另获授权撤销旧 UAT/PROD 注册和租约。删除旧 network/Gateway/state/DNS 是独立范围，不随本次重规划或业务部署自动执行。

该序列不包含 Shared ID/CIDR 迁移，不改变 Vault 主节点、Shared 服务入口或 Shared Gateway。

只读核查来源为 GitOps `e505d9e020986c1ba4df8c6ece80bc17f8a596ef` 的 [三网边界](https://github.com/ai-workspace-infra/gitops/blob/e505d9e020986c1ba4df8c6ece80bc17f8a596ef/topology/xconnect/network-boundaries.yaml)、[Shared One](https://github.com/ai-workspace-infra/gitops/blob/e505d9e020986c1ba4df8c6ece80bc17f8a596ef/vpn-overlay/shared/xconnect-vault-shared.yaml)、[UAT One](https://github.com/ai-workspace-infra/gitops/blob/e505d9e020986c1ba4df8c6ece80bc17f8a596ef/vpn-overlay/uat/xconnect-one-nodes.yaml)、[PROD One](https://github.com/ai-workspace-infra/gitops/blob/e505d9e020986c1ba4df8c6ece80bc17f8a596ef/vpn-overlay/prod/xconnect-one-nodes.yaml)。它们是声明证据，不是线上网络已打通的证明。

## 13. 2026-10-01 发布链路复核（未完成验收）

本节是运行状态快照，不代替上文目标契约，也不授权自动修复 Shared 服务或触发生产 DNS 切换。

| 检查项 | 当前证据 | 结果 / 下一步 |
| --- | --- | --- |
| Daily → UAT Hybrid | [Daily #36800539711](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36800539711)（`daily-build-2026.10.01-r1`，Shared readiness 每次均通过）逐个失败点修复后重跑失败 job，到第 7 次：GCP OS Login 链路通过（iac_modules#362、toolkit#1183/#1184/#1185、gitops#365）；Web SaaS 全链路通过（toolkit#1186，[Selfhost #36805004217](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36805004217)）；AI Workspace 全链路通过（playbooks#538，[Selfhost #36816022356](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36816022356)）；Serverless 通过并产出 `serverless-artifact-manifest`（toolkit#1187/#1188，[Serverless #36814917207](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36814917207)）；AWS JP 改以 admin 登录后 Bootstrap 通过（gitops#366），但在 [Selfhost #36816438929](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36816438929) 安装 Caddy 时因上游 apt 签名密钥过期失败（`EXPKEYSIG 531A6B20FA058A70`） | 未通过。按决定先缓解：playbooks#542 在密钥过期时移除 Caddy apt 源，绝不改为不校验签名；上游续期后对 #36800539711 只重跑失败 job。全部子 run success 前不得报 UAT 通过。 |
| Shared readiness | 2026-09-30 已恢复：[ZITADEL #36752612194](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36752612194) success，iam.svc.plus 的 HTTPS OIDC discovery issuer 正确，API/Login healthy；[Observability #36753310209](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36753310209) success，observability.svc.plus 的 Grafana 与 VM/VL/VT HTTPS 检查通过（migration_mode=none，历史数据仍在旧节点）。IAM 根因：GitOps 只传 `--config`，`start-from-init` 忽略 FirstInstance（gitops#363 加 `--steps`）；中断的首实例经确认后备份并重置 zitadel 库（playbooks#534、toolkit#1180，备份在 /var/backups/zitadel/）；Caddy reload 因 handler 丢失未生效（playbooks#536）。 | Daily 仍只读检查三项。待办：以 Vault 密码实测 zitadel-admin@iam.svc.plus 登录；Login PAT 持久化到 Vault（需管理员授权的窄写策略）；Observability 历史迁移需显式 `migrate` 并经审批。；2026-10-01 编排器 upgrade [#36797906295](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36797906295)：三份 Terraform state 无 delete/replace 均 success，Vault node-preflight success；ZITADEL 子 run 两次在 iam-shared-0 的 common 角色 `apt update` 失败（无报错原因；playbooks#537 已让 apt 输出原因，Caddy 密钥过期是最可能原因，playbooks#542 处理）。Daily 只读 readiness 仍通过。 |
| UAT Hybrid 与 Shared 隔离 | Hybrid 的普通 `all/deploy` 曾额外调用 `open-platform`，即使矩阵行标记 `release_scope=shared-infrastructure` | 本轮代码移除额外调用，并新增回归断言：业务 Hybrid 不派发该行；错误将它改成 `business` 时直接拒绝。仍需在合并后的 `main` 验证。 |
| Daily 等待子流水线 | UAT 等待用 60 分钟有效的 GitHub App token 读 Hybrid 状态，一次 API 读取失败即判 Daily 失败；PROD 用 `gh run watch`，遇 API 错误即退出 | 本轮改为共享 `wait-for-workflow-run.sh`：用 job `GITHUB_TOKEN` 读状态、有界容忍瞬时错误、只认子 run `success`、不重复派发；`daily_snapshot_run_wait_test.sh` 覆盖。仍需在合并后的 `main` 用真实 Daily run 验证。 |
| PROD 同制品晋级 | Serverless 同 digest 晋级契约已实现（见 GAP-16）：PROD 只接受 Daily 校验过、指向成功 UAT Hybrid run 的制品清单，按 digest 复制并核对服务中的 revision；`dispatch-prod-combined.sh` 仍直接扇出 Serverless、AWS 和 Akamai Selfhost | 未执行 PROD（需用户批准）。仍缺 PROD GitOps matrix、PROD Hybrid（GAP-06/07）、Selfhost 制品 digest 清单与独立 DNS 切换工作流；跨项目 AR 只读授权需审批。不能把 tag 一致误报成镜像一致。 |

本地 Daily 门禁、生产 manifest、Shared readiness 和 UAT matrix 契约测试通过，只证明对应代码路径；在上述线上失败和 PROD 差距未消除前，不标记 UAT 或 PROD 发布验收完成。

### 13.1 2026-10-01 后续运行检查点

- [Hybrid #36809717159](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36809717159)
  明确失败在 JP 子流程 [Selfhost #36812610735](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36812610735)：
  CMDB 为实例 `i-0289f628cb875beaf` 指定 `ansible_user=root`，SSH readiness 等待 600 秒后失败。
  GitOps [PR #366](https://github.com/ai-workspace-infra/gitops/pull/366) 随后将 JP Debian 声明改为
  `admin`；不得把这个 SSH 超时归因于 GCP OS Login 或只延长超时。
- [Hybrid #36813778329](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36813778329)
  为后续真实验证运行，检查时仍在执行；不重复派发，不预报成功。
- Hybrid 子流程等待改用 Daily 共用的有界状态等待器，默认每 30 秒观察一次；瞬时 API
  读取失败只重试观察，不取消、不重派发。匹配到多个候选 run 时拒绝选择“最新”作为验收
  证据。`hybrid_child_wait_test.py` 用模拟 API 验证恢复、真实失败停止和歧义拒绝。
- GCP OS Login 已有部署代码支持，但其共享 deploy key 当前默认 TTL 6h；尚未满足每 job
  独立临时 key、TTL ≤20m、任务后撤销及 runner `/32` 临时入口的完整目标。不能据此宣布
  SSH 权限收敛已完成。PROD Hybrid 与完整业务制品 digest 清单仍须继续实现。

### 13.2 PROD 制品证明不得由调用方自证

仅核对传入 manifest 的格式以及 `uat_run_id` 对应的 Hybrid run 成功，不能证明 manifest
中的 digest 确实被该 run 验收。调用方可以填写另一个格式合法的 digest、源码 SHA 或
Artifact Registry project，再引用同一个成功 run。

Daily 的 PROD dispatch 和 PROD Serverless 的独立 preflight 必须共同执行只读证明门禁：

1. 从 GitHub API 获取指定 UAT Hybrid run，要求 `completed/success`。
2. 从同一个仓库、同一个 run 下载 `uat-artifact-manifest`。
3. 规范化下载的 `uat-artifact-manifest.json` 与请求清单，逐项比较 snapshot、run、所有
   service、image、digest、source repository 和 source SHA。
4. 清单缺失、过期、下载失败或任何字段不同，均在派发/读取部署凭据之前失败。

`verify-accepted-promotion-manifest.sh` 为两个入口的共享门禁；
`prod_same_digest_promotion_test.sh` 覆盖格式合法的 digest、source SHA、外部 project 替换、
缺失 artifact，以及绕过 Daily 的直接 Serverless 请求。模拟测试通过不代表 PROD 已发布；
PROD Hybrid、Selfhost 制品证明、独立 DNS 审批及真实端到端验收仍未完成。

### 13.3 2026-10-02 晋级入口与 UAT AMI 漂移

- 定时 [Daily #36923755060](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36923755060)
  在 UAT Hybrid 的 AWS JP 子流程 [Selfhost #36924648401](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/36924648401)
  失败：Debian “most recent” AMI 查询从 `ami-09ddc97002eeb7efb` 变为 `ami-01c15b64fa74185e3`，
  plan 要替换 `i-0289f628cb875beaf`（2 add / 2 destroy），UAT apply 守卫正确拒绝。
  [gitops#369](https://github.com/ai-workspace-infra/gitops/pull/369) 将该主机固定到当前运行镜像，并要求 UAT
  Hybrid 路由的每台 AWS Terraform 主机都固定 `ami_id`；否则每个新上游镜像都会阻断 UAT 及其后的晋级。
- 重跑失败的 `promote-prod` job 使用原 run 的提交，修复无法生效；完整重跑 UAT 约需 1 小时。
  Daily `deploy_env=prod` 改为“晋级已验收的 UAT run”：必须填写 `uat_daily_run_id`，`resolve-accepted-uat`
  在 production 审批前、无任何凭据地只读验证——该 run 是本仓 `main` 上已结束的 Daily；最新 attempt 中
  UAT job 的 `Dispatch UAT Hybrid Orchestrator` 与 `Upload the verified UAT promotion manifest` 均 success
  （run 整体可因 `promote-prod` 失败而为 failure）；`uat-promotion-manifest` 从该 run 下载，不由调用方提供，
  并由 `verify-accepted-promotion-manifest.sh` 对照 UAT Hybrid run 自身 artifact 复核。UAT 专用输入
  （`repositories`、迁移、schema、基线、XConnect tag）在 PROD 一律拒绝，不静默丢弃。
- 旧的 PROD 直发步骤（从源码在四个组织打 `v*` tag、构建、触发 XConnect release 后才因缺清单被拒）
  已删除；`v*` tag 只由 `promote-prod` 创建。两个入口共用 `promote-prod`（production 审批、Shared
  readiness 复检、同一 Vault 角色），并以 job 级 concurrency 防止两次 PROD 晋级并行。
- 证据：`prod_accepted_uat_promotion_test.sh`（接受/拒绝用例及对解析脚本的变异测试）与
  `daily_snapshot_uat_gate_contract_test.sh` 真值表。仍未执行 PROD：跨项目 AR 只读授权、PROD AWS
  登录用户、PROD Hybrid（GAP-06/07）与 DNS 切换仍需单独审批。
