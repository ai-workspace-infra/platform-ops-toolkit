# Billing Caddy 跨节点入口交付记录

## 目标

在 UAT 打通以下现有职责边界：

```text
Xray -> xray-exporter -> Billing -> PostgreSQL -> Accounts -> Portal
agent-svc-plus ---------------------> Billing job trigger
Xray -> xray-exporter -> Vector/Observability -> Grafana  (实时监控，独立)
```

Billing 与 Accounts 继续共用 PostgreSQL；Billing 是计费写入唯一入口，Observability
不成为计费链路强依赖。

## 本次改动

- `deploy_base` 从 CMDB 中找出 `agent_proxy` 主机 IP，写入
  `WEB_SAAS_BILLING_ALLOWED_CIDRS`（IPv4 使用 `/32`，IPv6 使用 `/128`，多个
  CIDR 以空格分隔供 Caddy matcher 消费）；
- web-saas bootstrap 渲染 `billing-<env>.<TARGET_DOMAIN_BASE>`，只有域名与 CIDR
  同时存在时才启用 Caddy Billing 入口；
- agent-proxy 部署把 `BILLING_SERVICE_BASE_URL` 从 loopback 改为
  `https://billing-<env>.<TARGET_DOMAIN_BASE>`；
- UAT 未配置 `EXPORTER_SOURCES_JSON` 时，fallback source 改为 agent-proxy
  Caddy 的 HTTPS path，不再使用公网裸 `8080/8081`；
- 入口由 Caddy 按源 IP 限制到 agent-proxy，非允许来源返回 `403`；
- 所有逻辑放在 `.github/scripts/`，workflow 只调用脚本，不增加 inline shell。

## 影响范围

- 仅改变部署编排与 web-saas 主机 Caddy 配置；
- 不修改生产 Xray/Exporter，不修改 Billing/Accounts 数据模型；
- Exporter source 仍由 `EXPORTER_SOURCES_JSON` 提供，实时监控仍走
  Vector/Observability/Grafana；
- UAT DNS 声明由 `iac_modules` 的 `uat/web-saas.yaml` 增加
  `billing-uat.<domain>`，生产声明同步保留 `billing.<domain>` 以便后续显式启用。

## 验收

1. UAT DNS：`billing-uat.onwalk.net` 指向 web-saas 主机。
2. web-saas 主机：Caddyfile 出现 Billing host 与 agent CIDR matcher。
3. agent-proxy 主机：agent 配置的 `billing.baseURL` 为 HTTPS Billing 域名。
4. Billing 容器内请求两个 HTTPS Exporter source 的
   `/v1/snapshots/window`，返回 2xx 且 `node_id/env` 匹配。
5. agent-proxy 触发 `POST /v1/jobs/collect-and-rate` 与 `POST /v1/jobs/reconcile`
   成功，Billing 日志出现对应 job。
6. Billing 采集成功后检查 PostgreSQL 的分钟桶、ledger、quota state，最后刷新
   `console-uat.onwalk.net/panel/account`。

在合并和 UAT 部署前，不直接 SSH 手改 Caddyfile、DNS 或数据库。
