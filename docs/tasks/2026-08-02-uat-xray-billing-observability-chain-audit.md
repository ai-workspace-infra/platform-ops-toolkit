# UAT 两条 Xray 链路分段审计与验收清单

## 链路边界

账单统计链路：

```text
Xray -> ai-workspace-xstream/xray-exporter -> Vector -> Billing -> PostgreSQL -> Accounts -> Portal
```

实时监控链路：

```text
Xray -> xray-exporter -> Vector -> Observability -> Grafana
```

Billing 与 Accounts 共用 PostgreSQL；Billing 负责写入，Accounts 负责聚合查询，Portal 只消费 Accounts 接口。实时监控链路不依赖 Billing 成功，不能用 Grafana 页面可达证明账单落库，也不能用账单有数据证明 Grafana 已有 series。

## 固定验证基线

- 应用 tag：`uat-daily-build-2026.08.02-r5`
- Exporter 基础：上游 `compassvpn/xray-exporter v0.6.0`
- UAT Exporter release：`ai-workspace-xstream/xray-exporter:v0.6.0-uat.20260802.1`
- UAT 主机：web-saas `167.179.64.91`，agent-proxy `167.179.105.137`
- TLS：三个 UAT 域名使用 Vault 恢复的同一套 `*.${target_domain_base}` 证书

## 当前任务进度

| 阶段 | 状态 | 结论 |
| --- | --- | --- |
| Xray / Exporter | 已部署 | 两个 systemd exporter 服务应固定在 UAT release；需确认 `/scrape` 有用户维度样本。 |
| Vector 实时监控 | 已配置 | Xray scrape 与 Prometheus remote write 已有模板；需确认近期 series 到达 Observability。 |
| Vector Billing fan-out | 已修复并等待 UAT 重跑 | `VECTOR_SNAPSHOT_URL`、`VECTOR_BILLING_INGEST_*` 和 Vault token 已接入 UAT workflow。 |
| Billing / PostgreSQL | 已部署，待数据证据 | `BILLING_INGEST_MODE=push` 与共享 schema 已存在；需等 Vector accepted 后看 ingest、ledger/quota。 |
| Accounts / Portal | 页面可达，当前数据为空 | 0 B 是上游没有写入的下游表现，须在共库有新记录后复核。 |
| DNS | 自动更新已参数化 | `uat_dns_update=true` 时渲染 `billing-${DEPLOY_ENV}.${TARGET_DOMAIN_BASE}`、`console-...`、`accounts-...` 三条 A 记录。 |

## 每一跳只读检查

### Xray 与 Exporter

```bash
systemctl is-active xray xray-tcp xray-exporter-xhttp xray-exporter-tcp
curl -fsS http://127.0.0.1:8080/scrape | sed -n '1,80p'
curl -fsS http://127.0.0.1:8081/scrape | sed -n '1,80p'
```

通过标准：服务 active，两个 scrape endpoint 有用户/UUID 与上下行指标或等价快照字段。

### Vector 双平面

```bash
vector validate /etc/vector/vector.toml
grep -nE 'xray_(xhttp|tcp)_metrics|xray_snapshot_input|billing_snapshot_ingest|prometheus_remote' /etc/vector/vector.toml
journalctl -u vector --since '10 min ago' --no-pager \
  | grep -Ei 'xray|billing|remote_write|accepted|retry|401|403|404|5..' | tail -200
```

账单平面必须同时存在 `xray_snapshot_input`、Billing HTTP sink 和 2xx accepted；实时平面必须存在两个 Xray scrape source、Observability remote-write sink 且无持续 retry/5xx。

### Billing 与 PostgreSQL

```bash
curl -skS -o /dev/null -w '%{http_code}\n' https://billing-uat.onwalk.net/healthz
curl -skS -o /dev/null -w '%{http_code}\n' -X POST \
  https://billing-uat.onwalk.net/v1/ingest/snapshots \
  -H 'Content-Type: application/json'
```

无 token 的 ingest 探测应返回 401/403，而不是 DNS/TLS/连接失败。随后只读查询：

```sql
SELECT to_regclass('public.traffic_minute_buckets'),
       to_regclass('public.billing_ledger'),
       to_regclass('public.account_quota_states');
SELECT count(*), max(bucket_start) FROM public.traffic_minute_buckets;
SELECT count(*), max(created_at) FROM public.billing_ledger;
```

通过标准：表存在，并在产生可控测试样本后出现新的 bucket/ledger/quota 时间戳；不要手工写数据库。

### Accounts、Portal、Grafana

```bash
curl -fsS https://accounts-uat.onwalk.net/healthz
curl -fsS https://console-uat.onwalk.net/panel/account >/dev/null
```

使用实际账户认证请求 Accounts usage summary，核对 `usedBytes`、`remainingIncludedQuota`、`periodStart/periodEnd` 与共库一致；Portal 卡片必须与该 summary 一致。Grafana 最终要在最近 5 分钟看到 `job="xray"`、UAT instance、`transport=xhttp/tcp` 以及用户/UUID 维度 series，不能只以 dashboard 302/200 作为通过。

## DNS / TLS / 认证约束

DNS 由 workflow 的 `uat_dns_update` 控制，记录名和 zone 均从 `DEPLOY_ENV`、`TARGET_DOMAIN_BASE` 渲染；默认不更新，显式开启才执行。多 resolver 检查：

```bash
for resolver in 1.1.1.1 8.8.8.8; do
  dig +short @"$resolver" billing-uat.onwalk.net A
  dig +short @"$resolver" accounts-uat.onwalk.net A
  dig +short @"$resolver" console-uat.onwalk.net A
done
```

Billing Caddy 的 allowlist 从 CMDB 渲染 agent-proxy 源 CIDR；不得硬编码 `.64.91` 或 `.105.137`。三个域名都应使用 Vault 恢复的 wildcard TLS 文件；不得为了 UAT 排障重新申请生产证书。Exporter、Vector、Billing 共用的 `INTERNAL_SERVICE_TOKEN` 只从 Vault 注入，日志和文档不记录 token 值。

## 关联记录

- [UAT r5 fan-out 重跑记录](2026-08-02-uat-xray-billing-fanout-r5-rerun.md)
- [UAT r2 变更记录](2026-08-02-uat-r2-xray-billing-observability-change-log.md)
- [Domain Delivery Manifest](../domains/DELIVERY-MANIFEST.md)
