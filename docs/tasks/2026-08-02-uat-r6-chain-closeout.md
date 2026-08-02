# UAT r6：Xray 账单与实时监控链路收口记录

## 目标

账单统计链路：

```text
Xray -> ai-workspace-xstream/xray-exporter -> Vector -> Billing -> PostgreSQL -> Accounts -> Portal
```

实时监控链路：

```text
Xray -> ai-workspace-xstream/xray-exporter -> Vector -> Observability -> Grafana
```

两条链路共享 Exporter 采集，但 Billing 只接受 Vector push，不直接 pull Exporter；实时监控不依赖 Billing 成功。Billing 与 Accounts 共用 web-saas PostgreSQL，生产环境不在本次范围内。

## r6 发布基线

- 跨仓 tag：`uat-daily-build-2026.08.02-r6`
- Exporter：上游 `compassvpn/xray-exporter v0.6.0` 基础，UAT release `v0.6.0-uat.20260802.1`
- UAT 工作流：[`30758075573`](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30758075573)，部署与 DNS job 均为 success
- 快照构建：[`30757752806`](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30757752806)，跨仓快照成功
- GitOps r6 提交：`a99975f264c33b6b1bb0bca1c0fce7c7febfe72f`
- UAT 主机（本次 CMDB）：web-saas `167.179.105.137`，agent-proxy `167.179.64.91`

## 已合并变更

| 仓库 | PR | 结果 |
| --- | --- | --- |
| `ai-workspace-services/billing-service` | [#27](https://github.com/ai-workspace-services/billing-service/pull/27) | 已合并；Vector push ingest、共享 schema、周期配额链路 |
| `ai-workspace-xstream/xray-exporter` | [#12](https://github.com/ai-workspace-xstream/xray-exporter/pull/12) | 已合并；多节点/多 inbound 聚合与快照输出 |
| `ai-workspace-infra/playbooks` | [#224](https://github.com/ai-workspace-infra/playbooks/pull/224)、[#225](https://github.com/ai-workspace-infra/playbooks/pull/225)、[#226](https://github.com/ai-workspace-infra/playbooks/pull/226)、[#227](https://github.com/ai-workspace-infra/playbooks/pull/227) | 已合并；UAT fan-out、Exporter API 地址、Vector buffer、web-saas DNS alias |
| `ai-workspace-infra/platform-ops-toolkit` | [#244](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/244)、[#245](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/245) | 已合并；Vector 环境注入、参数化 DNS 流程 |
| `ai-workspace-infra/gitops` | [#134](https://github.com/ai-workspace-infra/gitops/pull/134) | 已合并；UAT web-saas 镜像版本轴 |

当前收口文档与 DNS 调用方改动仍需以 PR 方式进入 `platform-ops-toolkit/main`。

## r6 实测结果（修复前的阻断证据）

### Exporter 与 Vector

在 `agent-proxy.onwalk.net` 上确认：

- `xray`、`xray-tcp`、两个 `xray-exporter`、`vector` 均为 `active`。
- 两个 Exporter `/scrape` 均返回 `xray_up 1`。
- Vector 已渲染 `xray_xhttp_metrics`、`xray_tcp_metrics`、`xray_snapshot_input`、`billing_snapshot_ingest`、`prometheus_remote`。
- Billing disk buffer 已使用满足 Vector 最低要求的 `268435488` 字节。
- 最近窗口没有新的 Vector `ERROR`、HTTP 认证、404 或 retry 错误。

这证明采集端与双平面 fan-out 配置已落地，但还不能证明 Billing 收到并落库。

### DNS 与 Billing 阻断

r6 DNS job 成功后，用两个公共 resolver 查询到：

```text
billing-uat.onwalk.net  -> 167.179.64.91
accounts-uat.onwalk.net -> 167.179.64.91
console-uat.onwalk.net  -> 167.179.64.91
```

而本次 CMDB 明确显示 web-saas 为 `167.179.105.137`、agent-proxy 为 `167.179.64.91`。原因是原 DNS reconcile 只从生产 `service_domains` 推导记录；UAT 的 `console/accounts/billing-uat.onwalk.net` 没有生产源域名可替换，旧记录因此没有被覆盖。

在 agent-proxy 侧访问 Billing 得到：

- `/v1/ingest/snapshots` 返回 `404 page not found`。
- `/v1/status` 仍显示 `xhttp-local` direct-pull 与 `account_user` 密码认证失败。
- `/healthz` 返回 `503 degraded`。

这组结果与流量仍落到旧/错误 Billing 入口一致，不能作为 r6 应用已收敛的证据；当前不得释放 UAT VPS。

## 已完成的最小修复

`playbooks#227` 已合并：`update_site_dns.yml` 支持接收参数化 alias records，并从 `web_saas` inventory group 解析当前 IP。

调用方下一步会由 `platform-ops-toolkit` 根据：

```text
DNS_SERVICE_NAMES=console accounts billing
DEPLOY_ENV=uat
PROVISION_TARGET_DOMAIN_BASE=onwalk.net
```

渲染三条记录，目标始终取当前 `web_saas` 主机，不硬编码 VPS IP：

```text
console-uat.onwalk.net  -> 当前 web_saas IP
accounts-uat.onwalk.net -> 当前 web_saas IP
billing-uat.onwalk.net  -> 当前 web_saas IP
```

## 最终验收门槛

修复 PR 合并并重跑 r6 后，按以下顺序逐段验收：

1. DNS 三条记录都指向本次 CMDB 的 web-saas IP；TLS 仍来自 Vault 恢复的 wildcard 证书。
2. `xray-exporter` 两个 `/scrape` 返回 `xray_up 1` 且有用户/UUID 维度数据。
3. Vector Billing sink 出现成功交付；未认证直接访问 ingest 必须是 `401/403`，不能是 `404`。
4. Billing `/v1/status` 为 push ingest，且 `/healthz` 不再报告 direct-pull source/auth failure。
5. PostgreSQL 中 `traffic_minute_buckets`、`billing_ledger`、`account_quota_states` 有新时间戳/记录。
6. Accounts `/api/account/usage/summary` 返回非零使用量或明确的本周期数据，包含 `periodStart/periodEnd`。
7. Portal `/panel/account` 的配额卡显示 Accounts summary，而不是 0 B 空状态。
8. Vector Prometheus remote write 成功，Grafana Xray dashboard 最近窗口出现 UAT series；此项与 Billing 独立验收。

全部门槛通过、证据写回本记录并完成相关 PR 合并后，才允许 dispatch `action=destroy` 释放两台 UAT VPS。释放动作本身必须单独记录 workflow run、destroy 结论和资源核对结果。

## 关联入口

- [两条链路分段审计清单](2026-08-02-uat-xray-billing-observability-chain-audit.md)
- [r5 fan-out 重跑记录](2026-08-02-uat-xray-billing-fanout-r5-rerun.md)
- [UAT r2 变更记录](2026-08-02-uat-r2-xray-billing-observability-change-log.md)
- [Domain Delivery Manifest](../domains/DELIVERY-MANIFEST.md)
