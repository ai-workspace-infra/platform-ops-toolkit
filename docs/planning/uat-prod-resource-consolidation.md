# UAT / PROD IaC 资源压缩评估

目标：每个环境只保留 6 台基础节点，由它们承载 Vault、Observability、
AI Aggregator Gateway、CPA 与 XConnect，UAT / PROD 之间尽量共享同一套资源。

## 0. 设计原则

1. **ai-aggregator 可独立部署，也可混合部署。** Gateway / CPA 是逻辑节点。
   独立模式下由 `resource_contract` 拉起专用实例（现有 Akamai 路径）；
   混合模式下落到已有的 open-platform / agent-proxy 上。两种模式用同一份清单，
   只切换放置方式。
2. **XConnect Gateway / One（Zero 信任网络）可独立部署，也可混合部署。**
   可以是专用节点（例如现在的 `tw-xconnect.svc.plus`），也可以与
   agent-proxy 共用 Caddy 443（`frontend: caddy-unix-h2c`，路径 `/xconnect`），
   互不抢占端口。
3. **agent-proxy-\* 2C2G 可承载 XConnect Gateway/One 和 CPA-\*。**

## 1. selfhost base 模版（GCP UAT）

下面 6 台是 selfhost 自建的 **base 模版**，可以增加，也可以缩减。
每个 workload 对应一份独立声明 `resources/xworktech.com/uat/gcp/<name>-workload.yaml`
（ai-workspace-infra/gitops），各自使用独立的 VPC、子网和 Terraform state。
因此增加或删除一台，不会影响其他节点。

`.github/workflows/gcp-uat-workload-sequence.yml` 的 `workloads` 输入决定
这次运行哪些节点（默认就是下面 6 台），按列表顺序逐个 plan / apply / destroy：

- 扩容：在 GitOps 里新增 `<name>-workload.yaml`（新子网不能与已有子网冲突），
  再把 `<name>` 加进 `workloads`。
- 缩容：`deploy_action=destroy workloads=<name>`，然后删除该声明。

| 节点 | 规格 | GCP machine_type | Region | 子网 |
| --- | --- | --- | --- | --- |
| open-platform | 2C4G Spot | `e2-custom-2-4096` | asia-east1 | 10.62.0.0/24 |
| web-saas | 2C4G Spot | `e2-custom-2-4096` | asia-east1 | 10.63.0.0/24 |
| ai-workspace | 4C8G Spot | `e2-custom-4-8192` | asia-east1 | 10.64.0.0/24 |
| agent-proxy-jp | 2C2G Spot | `e2-highcpu-2` | asia-northeast1 | 10.65.0.0/24 |
| agent-proxy-us | 2C2G Spot | `e2-highcpu-2` | us-central1 | 10.66.0.0/24 |
| agent-proxy-sg | 2C2G Spot | `e2-highcpu-2` | asia-southeast1 | 10.67.0.0/24 |

2C4G 选 `e2-custom-2-4096`，没有选 `e2-medium`。原因是 e2-medium 是共享核，
持续算力只有 1 vCPU。

## 2. 压缩方案（混合模式放置）

| 服务 | 独立模式（现状） | 混合模式 |
| --- | --- | --- |
| vault.svc.plus | shared 3 节点 Raft（vault-prod-0..2） | open-platform（PROD）作为 leader，UAT 不再单独部署 Vault |
| observability.svc.plus | Akamai open-platform 入口 | open-platform，UAT/PROD 共用一套，按 `environment` 标签区分 |
| AI Gateway（Caddy + Kong + New API + LiteLLM） | 专用 gateway-01 | 每个环境的 open-platform（`caddy_mode: reuse-existing`） |
| XConnect Gateway | 专用 `tw-xconnect.svc.plus` | agent-proxy-jp（与 Gateway / CPA 主区域同区，路径 `/xconnect`） |
| XConnect One | 各业务节点 | open-platform、web-saas、ai-workspace、agent-proxy-us/sg |
| cpa-codex-01 | 专用节点 | agent-proxy-jp |
| cpa-claude-01 | 专用节点 | agent-proxy-us（Anthropic 出口区域最稳妥） |
| cpa-grok-01 | 专用节点 | agent-proxy-sg |
| cpa-codex-02 | 专用节点 | agent-proxy-jp（端口 8320，与 codex-01 的 8317 不冲突） |

节点数：每个环境 6 + 5（AI Aggregator 专用）+ 1（XConnect Gateway）→ 6。
Akamai 上 5 台 g6-standard-1 可以下线；独立模式仍然保留，需要时可以随时拉起。

agent-proxy 2C2G 的内存预算（估算）：

| 组件 | 内存 |
| --- | --- |
| OS + Caddy | ~350M |
| agent-proxy（xray） | ~100M |
| XConnect Gateway 或 One（xray + WireGuard） | ~100M |
| CPA（CLIProxyAPI），每实例 | ~150M |
| CodeAgent CLI（codex / claude-code / grok），运行时 | ~300–800M |
| **合计** | **~1.0–1.5G，2G 可承载** |

前提是不安装桌面（xrdp / KDE），只启用 `ai_desktop_cpa_codeagent`。
agent-proxy-jp 同时承载 XConnect Gateway 和 2 个 codex CPA，是最紧的一台；
如果 CodeAgent 需要并发常驻，把 codex-02 挪到 agent-proxy-sg，或者只把
jp 升到 2C4G。

## 3. 风险与前置条件（必须先解决）

1. **Spot 生命周期。** `modules/spot_vm` 固定写入 `max_run_duration`，
   而且 `instance_termination_action = DELETE`。所有 GCP UAT 节点在 1 小时后
   会被自动删除。按现在的模块，这些节点撑不起 Vault、Observability 或
   Gateway 这类长驻服务。
   → iac_modules 需要支持 `provisioning_model: STANDARD`，或让
   `max_run_duration` 变成可选。PROD 的 open-platform 不能用 Spot。
2. **open-platform 2C4G 内存不够。** ai-aggregator 清单自己声明的
   `minimum_resources` 就是 2C4G，`recommended` 是 4C8G；再叠加
   Vault（约 0.5G）和 observability 栈（约 1–1.5G），会超出 4G。
   → 可选：PROD open-platform 升到 `e2-standard-2`（2C8G）或 4C8G；
   或者把 observability 挪到 ai-workspace（4C8G）。
3. **agent-proxy 2C2G。** 预算见第 2 节。目前 GCP UAT 流程
   （`uat-gcp-auto-deploy`）会对 CPA 执行 `deploy_ai_desktop.yml
   ai_desktop_remote_enabled=true`，混合模式下必须改成与 Akamai 路径一致的
   `ai_desktop_cpa_codeagent=true ai_desktop_remote_enabled=false`。
4. **跨 VPC、跨区域的私网。** CPA 要求 `transport: private-network-required`，
   而 GCP 这 6 个 workload 各自独立 VPC，没有 NAT、也没有 peering。
   → Gateway 到 CPA 必须走 XConnect overlay（清单里已经分配了
   10.77.0.10–14），`network_endpoint` 要改成 overlay IP。
5. **制品架构不一致。** 清单要求 `arch: arm64`，但 Akamai g6 和 GCP e2
   都是 amd64。→ 改成 amd64 制品，或者改用 t2a（Arm）机型。
6. **Stage 被阻塞。** 在 `spec.enabled: true`，并且 new_api / cliproxyapi 的
   `revision` 和 `sha256` 都填好之前，`deploy-ai-aggregator-v1.yml` 会拒绝
   stage/activate。目前只能执行 `operation=provision`。
7. **CPA 账号是稀缺资源。** 同一个订阅账号（OAuth 会话）不能在 UAT 和
   PROD 各跑一份。→ CPA 只部署一份（PROD 的 agent-proxy），UAT / PROD
   两个 Gateway 用不同的 JWT audience 共用它；或者 UAT 使用独立账号。

## 4. IaC 改动清单

1. gitops `topology/<env>/selfhost/ai-aggregator.yaml`：给每个 `nodes[]`
   增加放置字段，让两种模式共用一份清单：

   ```yaml
   nodes:
     - id: gateway-01
       placement: colocated        # dedicated | colocated
       inventory_host: open-platform
     - id: cpa-codex-01
       placement: colocated
       inventory_host: agent-proxy-jp
   ```

   `resource_contract.manifests` 只保留 `placement: dedicated` 的节点。
   CPA 的 `network_endpoint` 改为 XConnect overlay 地址。
2. gitops `vpn-overlay/<env>/xconnect-one-nodes.yaml`：采用同样的
   `placement`。`gateway_ref` 可以指向专用节点，也可以指向 agent-proxy-jp；
   agent-proxy-* 加入 `fixed_nodes`（`lifecycle: persistent`）。
3. platform-ops-toolkit `ai-aggregator-v1.yml`：`resolve-provider` 按
   `placement` 拆出两路。dedicated 节点走现有的 provider 矩阵；colocated
   节点走一个新的 `uat-existing-deploy` job（与 `prod-deploy` 同形，只跑
   Ansible，不建也不删资源，`--limit` 为 colocated 主机）。本分支新增的
   `nodes` 输入已经可以对 dedicated 矩阵做子集选择。
4. iac_modules `gcp-cloud/modules/spot_vm`：生命周期参数化（见 3.1）。
5. 全部切到混合模式、稳定之后，再评估是否删除 gitops 里的
   `resources/svc.plus/uat/akamai/ai-aggregator-*.yaml`；独立模式仍需要它们。

## 5. 过渡期

切换完成之前，Akamai 专用节点仍然可以用 `ai-aggregator-v1.yml` 按需拉起。
用 `nodes` 输入只选需要的节点：

```
operation=provision environment=uat provider=akamai-cloud
nodes=gateway-01,cpa-codex-01,cpa-claude-01,cpa-grok-01
```
