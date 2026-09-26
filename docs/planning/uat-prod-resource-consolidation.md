# UAT / PROD IaC 资源压缩评估

目标：每个环境只保留 6 台基础节点，由它们承载 Vault、Observability、
AI Aggregator Gateway 与 CPA，UAT / PROD 之间尽量共享同一套资源。

## 1. 目标节点规格（GCP UAT）

GitOps 声明：`resources/xworktech.com/uat/gcp/*-workload.yaml`
（ai-workspace-infra/gitops，分支 `claude/gifted-cannon-t30xak`）。
由 `.github/workflows/gcp-uat-workload-sequence.yml` 按顺序 plan/apply。

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

## 2. 压缩方案

| 服务 | 现状 | 压缩后 |
| --- | --- | --- |
| vault.svc.plus | shared 3 节点 Raft（vault-prod-0..2） | open-platform（PROD）作为 leader，UAT 不再单独部署 Vault |
| observability.svc.plus | Akamai open-platform 入口 | open-platform，UAT/PROD 共用一套，按 `environment` 标签区分 |
| AI Gateway（Caddy + Kong + New API + LiteLLM） | 专用 gateway-01 | 每个环境的 open-platform（`caddy_mode: reuse-existing`） |
| cpa-codex-01 | 专用节点 | agent-proxy-jp |
| cpa-claude-01 | 专用节点 | agent-proxy-us（Anthropic 出口区域最稳妥） |
| cpa-grok-01 | 专用节点 | agent-proxy-sg |
| cpa-codex-02 | 专用节点 | agent-proxy-jp（端口 8320，与 codex-01 的 8317 不冲突） |

节点数：每个环境 6 + 5（AI Aggregator 专用）→ 6，Akamai 上 5 台
g6-standard-1 全部下线。

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
3. **agent-proxy 2C2G。** CLIProxyAPI 本身很轻，但 CPA 节点还带
   `ai_desktop` CodeAgent（codex / claude-code / grok CLI），和 agent-proxy
   叠加后 2G 很紧。→ 共享节点上关掉 desktop remote（xrdp），
   保留 `ai_desktop_cpa_codeagent`。如果 CodeAgent 需要常驻，升到 2C4G。
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

1. gitops `topology/<env>/selfhost/ai-aggregator.yaml`：
   把 `infrastructure.provider` 改为 `existing`，`nodes[].inventory_host`
   指向 open-platform / agent-proxy-*，删掉 `resource_contract.manifests`。
2. platform-ops-toolkit `ai-aggregator-v1.yml`：`resolve-provider` 已经接受
   `existing`，但 UAT 还没有对应的 job。需要新增一个与 `prod-deploy`
   同形的 `uat-existing-deploy`（只跑 Ansible，不建也不删资源）。
3. iac_modules `gcp-cloud/modules/spot_vm`：生命周期参数化（见 3.1）。
4. 切换完成后，删除 gitops 里 `resources/svc.plus/uat/akamai/ai-aggregator-*.yaml`
   这 5 个声明。

## 5. 过渡期

切换完成之前，Akamai 专用节点仍然可以用 `ai-aggregator-v1.yml` 按需拉起。
用 `nodes` 输入只选需要的节点：

```
operation=provision environment=uat provider=akamai-cloud
nodes=gateway-01,cpa-codex-01,cpa-claude-01,cpa-grok-01
```
