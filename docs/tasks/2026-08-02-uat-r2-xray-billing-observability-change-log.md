# UAT r2：Xray → Exporter → Billing → PostgreSQL → Accounts → Portal 变更记录

> 发布标识：`uat-daily-build-2026.08.02-r2`
> 记录日期：2026-08-02
> 适用环境：UAT（`console-uat.onwalk.net`、`agent-proxy.onwalk.net`）
> 生产约束：本轮未修改生产 Xray、生产 Exporter 或生产数据库。

## 1. 本轮目标与边界

本轮围绕两条相互独立的链路推进：

```text
计费统计链路：
Xray → compassvpn/xray-exporter v0.6.0 → Billing → 共用 PostgreSQL
        → Accounts 聚合接口 → Portal /panel/account

实时观测链路：
Xray → compassvpn/xray-exporter → Vector / Observability Server → Grafana
```

计费链路以 Billing 和 Accounts 共用数据库为前提，不拆分数据库；实时观测链路只负责监控分析，不作为计费写入链路的强依赖。

UAT 的验证基线是多节点、多 inbound 按同一用户邮箱和 UUID 聚合。即使同一账户同时出现在多个 Xray 节点或多个 inbound，Billing 也必须按账户维度累计，而不是按线路分别计费。

## 2. r2 发布结果

### 2.1 构建与部署引用

| 项目 | r2 结果 |
| --- | --- |
| Daily snapshot workflow | [Run 30732777269](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30732777269) 成功 |
| UAT deploy workflow | [Run 30732938304](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30732938304) 进行中 |
| Exporter 基础版本 | `compassvpn/xray-exporter v0.6.0` |
| UAT Exporter 版本 | `v0.6.0-uat.20260802.1` |
| 统一部署 tag | `uat-daily-build-2026.08.02-r2` |
| GitOps 状态 | [gitops#131](https://github.com/ai-workspace-infra/gitops/pull/131) 已合并 |

GitOps `main` 当前已将 Web SaaS 镜像指向：

```text
ACCOUNTS_IMAGE=ghcr.io/ai-workspace-services/accounts:uat-daily-build-2026.08.02-r2
BILLING_IMAGE=ghcr.io/ai-workspace-services/billing-service:uat-daily-build-2026.08.02-r2
CONSOLE_IMAGE=ghcr.io/ai-workspace-services/console:uat-daily-build-2026.08.02-r2
```

### 2.2 已完成的功能变更

- Exporter 以 `compassvpn/xray-exporter v0.6.0` 为基础，保留快照采集、身份解析和 HTTP 采集能力。
- Billing 修复多节点、多 inbound 样本按 UUID 聚合后再计费的问题。
- Accounts 初始化共享计费依赖 Schema，补齐 UAT 缺失的 `traffic_minute_buckets`、`billing_ledger`、`account_policy_snapshots`、`node_health_snapshots` 等表。
- Accounts 持久化订阅周期边界，支持 Portal 展示本期使用量、剩余配额和重置时间。
- Portal 保留原有账户、订阅、取消订阅、MFA、VLESS 和连接功能，并补充配额/周期展示。
- Playbooks、Platform Ops 和 GitOps 打通 UAT Exporter 的运行时 source routing，避免把远端 Exporter 错误配置为本机回环地址。
- UAT workflow 的 Exporter 参数已收敛，固定使用已验证的 `v0.6.0-uat.20260802.1`，并提供 UAT-only fallback；生产不使用该 fallback。

## 3. 对应 PR 清单

以下 PR 均以 PR 方式合并到目标仓库的 `main`，没有绕过评审直接写入 `main`。

### 3.1 业务服务与 Portal

| 仓库 | PR | 变更内容 | 合并提交 |
| --- | --- | --- | --- |
| `ai-workspace-xstream/xray-exporter` | [#6](https://github.com/ai-workspace-xstream/xray-exporter/pull/6) | 以 upstream `compassvpn/xray-exporter v0.6.0` 为基础，接入快照身份与采集实现 | `d1c045bc49f38bb6abe140cadfb4746a98a8a8d9` |
| `ai-workspace-services/billing-service` | [#24](https://github.com/ai-workspace-services/billing-service/pull/24) | 多 inbound / 多节点按 UUID 聚合后计费 | `5fbf776dd44d518315355052022aff765e84ce9d` |
| `ai-workspace-services/billing-service` | [#25](https://github.com/ai-workspace-services/billing-service/pull/25) | UAT Xray 计费链路审计记录 | `917de306b9697798a14cfedf2d3f59241fbba981` |
| `ai-workspace-services/billing-service` | [#26](https://github.com/ai-workspace-services/billing-service/pull/26) | 核心 Xray 计费写入链路设计记录 | `8be07e1fb88c6a383b6954aa8971aab77f9aa71f` |
| `ai-workspace-services/accounts` | [#45](https://github.com/ai-workspace-services/accounts/pull/45) | 持久化 `period_start` / `period_end` 周期边界 | `8581f7f8e7a292d1524283bc2b41f33fa35c7963` |
| `ai-workspace-services/accounts` | [#46](https://github.com/ai-workspace-services/accounts/pull/46) | 幂等初始化共享计费 Schema | `41d25d20a147c40aa4f5988cb37403677b28caa3` |
| `ai-workspace-services/portal` | [#133](https://github.com/ai-workspace-services/portal/pull/133) | 账户页面国际化、配额/周期展示及冲突合并 | `2fcc5c862e001563c819c77c38de7589da0e0907` |

### 3.1.1 冲突 PR 处理

以下两个旧 PR 已在本轮核对后关闭，不属于 r2 的待合并变更：

- [xray-exporter#4](https://github.com/ai-workspace-xstream/xray-exporter/pull/4)：原有身份 alias 规范化逻辑已由 #6 的 `internal/snapshot/identities.go`、`internal/snapshot/service.go` 和对应测试覆盖；旧 PR 依赖的 `internal/accounts` / `internal/service` 已被 v0.6.0 快照架构替代。
- [xray-exporter#5](https://github.com/ai-workspace-xstream/xray-exporter/pull/5)：原有 `internal/xray` Prometheus/JSON client 已被 #6 的 gRPC `Exporter.TrafficCounters` 替代；如果未来需要消费 legacy Prometheus，需要按当前 snapshot interface 新建 source adapter。

关闭说明已分别记录在 [#4 comment](https://github.com/ai-workspace-xstream/xray-exporter/pull/4#issuecomment-5155506898) 和 [#5 comment](https://github.com/ai-workspace-xstream/xray-exporter/pull/5#issuecomment-5155507194)。

### 3.2 部署、路由与 UAT 运维

| 仓库 | PR | 变更内容 | 合并提交 |
| --- | --- | --- | --- |
| `ai-workspace-infra/playbooks` | [#222](https://github.com/ai-workspace-infra/playbooks/pull/222) | Exporter systemd、环境文件、source routing 与部署任务 | `09ee32320367c5d96928e610fc80924c094810f9` |
| `ai-workspace-infra/platform-ops-toolkit` | [#232](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/232) | 从 Vault 向 Agent Proxy 传递 Exporter source 配置 | `3ce3401806618bb36e13c3a1d53b8ace60f29f05` |
| `ai-workspace-infra/platform-ops-toolkit` | [#233](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/233) | 压缩 workflow dispatch 输入并保留 UAT 路由参数 | `80372d14967a149fdfab9037af677d92134ee3e0` |
| `ai-workspace-infra/platform-ops-toolkit` | [#234](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/234) | UAT-only Exporter source fallback | `3915e545c1182baeb84622c5dde5e59e1f2d99fd` |
| `ai-workspace-infra/platform-ops-toolkit` | [#236](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/236) | UAT snapshot 部署进度与观测记录 | `4ea99ea4a7f4bcddfb24fb7b182d5a2b6d38c1f8` |
| `ai-workspace-infra/gitops` | [#131](https://github.com/ai-workspace-infra/gitops/pull/131) | UAT 镜像 tag、远端 Exporter source routing 和交付校验 | `954bcbbd34e720eabfef7625547851197d5cfdd0` |

## 4. UAT 当前验证状态

[UAT workflow 30732938304](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30732938304) 的已完成阶段：

- UAT profile 解析、资源准备和初始化成功。
- `agent-proxy.onwalk.net`、`console-uat.onwalk.net` 节点 bootstrap 成功。
- GitOps deploy tag 自动更新成功。
- Web SaaS PostgreSQL 数据库初始化成功。
- Web SaaS 服务部署成功。
- Web SaaS observe 阶段成功。

截至本记录更新时仍在运行：

- `Deploy Monitor Agent (console-uat.onwalk.net)`
- `Deploy Monitor Agent (agent-proxy.onwalk.net)`
- `Deploy Agent Proxy Services on agent-proxy.onwalk.net`

因此，`/panel/account` 最终出现真实采集统计、Grafana 出现实时 Xray 指标，仍需在上述步骤完成后执行端到端验收，当前不能标记为最终通过。

## 5. 观测链路与计费链路的判定标准

计费链路验收必须确认：

1. Exporter 能从多个 Xray 节点读取同一账户的 UUID、邮箱和上下行字节。
2. Billing 对同一 UUID 的多 inbound 样本只聚合一次后写入共享 PostgreSQL。
3. `traffic_minute_buckets`、`billing_ledger`、`account_quota_states` 和周期字段均可读写。
4. Accounts `/api/account/usage/summary` 返回非零 `totalBytes`、`usedBytes` 或有效配额周期。
5. Portal `/panel/account` 的用量、余额、周期重置和同步状态与 Accounts 返回一致。

实时观测链路验收必须单独确认：

1. Exporter 暴露 Xray 用户维度指标。
2. Vector 或 Observability Server 能抓取并转发指标。
3. Grafana Xray Dashboard 在 `now-5m` 范围内出现用户、实例和上下行数据。

此前 UAT 观察到 Vector 对 `127.0.0.1:9100/metrics` 返回 503、对 `127.0.0.1:9256/metrics` 超时。这属于 Monitor Agent / exporter 观测侧问题，不应阻断 Billing → PostgreSQL → Accounts 的计费写入，但必须在 UAT 验收中单独记录和修复。

## 6. 未纳入 r2 的项目

- `xray-exporter#4` 和 [#5](https://github.com/ai-workspace-xstream/xray-exporter/pull/5) 仍为 OPEN 的历史探索 PR；r2 使用的是已合并的 #6，不应与 #6 重复合并。
- Billing 的多表写入事务化、失败重试/outbox 等增强设计尚未作为本轮代码落地；r2 先完成聚合修复、共享 Schema、周期字段和端到端可观测路径。
- 生产环境 Xray → Exporter → Observability 链路仅作为对照基线评估，本轮没有生产变更。

## 7. 下一步验收顺序

1. 等待 [UAT workflow 30732938304](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30732938304) 完成。
2. 在 UAT 检查 Exporter、Vector、Monitor Agent 和 Agent Proxy 服务状态。
3. 使用 UAT 已配置账户产生一小段可控流量，分别验证 Billing 数据库和 Accounts summary。
4. 刷新 `https://console-uat.onwalk.net/panel/account`，核对用量、余额和周期。
5. 打开 Grafana Xray Dashboard，确认实时监控数据出现；若仍无数据，沿观测链路排查，不回滚计费链路。
6. 将命令输出、页面截图、Grafana 查询结果和最终结论补充到本记录末尾。
