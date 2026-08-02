# UAT r5：Xray → Exporter → Vector → Billing 闭环重跑

## 背景

`uat-daily-build-2026.08.02-r5` 已部署 Billing push ingest、共享 PostgreSQL schema、Accounts 聚合接口和 Portal 配额卡，但数据仍为 0。排查确认原因不是数据库 schema，而是采集端 fan-out 没有被 workflow 注入：Vector billing source/sink 未渲染，Exporter 也没有 `VECTOR_SNAPSHOT_URL`。

同时，`billing-uat.onwalk.net` 的权威 DNS 已手动指向 Billing Caddy 所在的 `167.179.64.91`。Caddy allowlist 由现有部署步骤从 CMDB 自动解析真实 agent-proxy 地址；当前应为 `167.179.105.137/32`，否则 host route 会返回 403。

## 本次最小修复

- UAT agent-proxy 部署注入：
  - `VECTOR_SNAPSHOT_URL=http://127.0.0.1:8686`
  - `VECTOR_BILLING_INGEST_ENABLED=true`
  - `VECTOR_BILLING_INGEST_ADDRESS=127.0.0.1:8686`
  - `VECTOR_BILLING_INGEST_URL=https://billing-uat.onwalk.net/v1/ingest/snapshots`
  - `INTERNAL_SERVICE_TOKEN` 从 Vault `kv/data/WEB_SAAS` 注入
- web-saas Caddy 的 Billing allowlist 继续由 CMDB 解析，不硬编码生产 IP。
- 生产环境不启用上述 UAT fan-out 配置；Exporter 版本保持 `v0.6.0-uat.20260802.1`，应用 tag 保持 r5。

## 验收顺序

1. Vector 配置存在 `xray_snapshot_input` 与 `billing_snapshot_ingest`，并有 accepted/retry 日志。
2. Billing `/v1/ingest/snapshots` 返回成功，且 Bearer token 认证通过。
3. PostgreSQL 的 `traffic_minute_buckets`、`billing_ledger`、`account_quota_states` 出现对应账户数据。
4. Accounts `/api/account/usage/summary` 返回非零 `usedBytes/totalBytes` 或明确的周期状态。
5. Portal `/panel/account` 展示用量、配额、剩余量和周期字段。
6. Vector Prometheus remote write 成功，Grafana Xray dashboard 出现 UAT series；该实时监控平面不依赖 Billing ingest 成功。
