# PROD Agent Proxy 调试与验收 Runbook

> 状态：基础服务与实时监控链路已通过；计费面板仍需单独验收
> 记录日期：2026-09-04（Asia/Shanghai）
> 环境：PROD
> 目标节点：`agent-proxy-selfhost-prod.svc.plus`
> 关联 IaC：[`iac_modules` PR #263（MERGED）](https://github.com/ai-workspace-infra/iac_modules/pull/263)

## 1. 目标与边界

本 Runbook 用于验证 AWS T4G ARM64 Agent Proxy 从节点、TLS、VLESS、Xray、Exporter、Vector、Billing、Accounts 到 Portal 的分段状态。

实时监控和计费面板是两条不同的数据平面：

```text
实时监控：Xray -> Exporter /scrape -> Vector Prometheus remote write -> Prometheus -> Grafana
计费面板：Xray -> Exporter snapshot -> Vector HTTP sink -> Billing -> PostgreSQL
          -> Accounts /api/account/usage/summary -> Portal /panel
```

Grafana 有数据，只能证明实时监控平面收到了指标；不能证明 Billing 已写入分钟桶，也不能证明 Accounts 已按当前登录用户返回用量。

## 2. 本次生产发布基线

| 项目 | 结果 |
| --- | --- |
| Daily Snapshot | [run 33837406401](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/33837406401) SUCCESS |
| 实际生产版本 | `v2026.09.04-r6`，源引用为 `uat-daily-build-2026.09.04-r10` |
| PROD Agent Proxy | [run 33838334852](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/33838334852) SUCCESS |
| 节点规格 | AWS T4G，ARM64，2C1G，绑定 EIP |
| 当前 EIP | `35.79.83.48` |
| DNS | `agent-proxy-selfhost-prod.svc.plus` 为 A 记录，当前解析到 `35.79.83.48`；节点代理模式为 DNS-only |
| 节点根探针 | `https://agent-proxy-selfhost-prod.svc.plus/` 返回 `Agent Service Plus Node` / HTTP 200 |
| Grafana | 已观察到 `agent-proxy-selfhost-prod.svc.plus`、`admin@svc.plus` 的上下行指标 |

不要把本表中的 EIP、域名或用户邮箱当作账单主键。账单主键必须使用 Accounts 的 canonical account UUID。

## 3. 已解决的节点问题

### 3.1 AWS Debian 登录用户

AWS Debian 云主机默认 SSH 用户为 `admin`；Ubuntu 默认用户为 `ubuntu`，其他镜像需按镜像约定处理。不得把 Debian AWS 主机默认写成 `root`。

### 3.2 ARM64 二进制

节点 `uname -m` 为 `aarch64`。Xray、xray-exporter 及 Vector 安装步骤必须根据 `ansible_architecture` 选择 ARM64 包或二进制；否则会出现：

```text
Exec format error
status=203/EXEC
```

### 3.3 通用域名模板

生产配置不得继续使用 `tky-proxy` 作为模板文件名或站点名。Caddy 片段应使用通用的 `agent-proxy.caddy`，站点名从节点域名变量渲染。

### 3.4 Caddy 与 XHTTP 路由

生产节点应满足以下契约：

- TLS 证书覆盖 `agent-proxy-selfhost-prod.svc.plus`；
- `/split` 与 `/split/*` 转发到 `/dev/shm/xray.sock`；
- XHTTP 使用 h2c upstream；
- `/xray-exporter/xhttp/*` 和 `/xray-exporter/tcp/*` 仅用于受控的 Billing snapshot 拉取；
- 不依赖手工在 Caddy 中修正客户端协议参数。

`x_padding=` 不是该节点需要的连接参数。Caddy 的删除空参数只能作为兼容性兜底；正确修复是在前端生成 VLESS 订阅链接时，不生成空的 `x_padding` 查询参数。

### 3.5 TLS 直连排查

若日志出现：

```text
no certificate available for '172.31.5.253'
```

通常表示客户端未发送 SNI，或使用了私网 IP 作为 TLS ServerName。必须使用节点域名作为 `host` / `sni`，不能用私网 IP 代替域名验证。

## 4. 节点只读检查

在节点上执行：

```bash
hostname -f
uname -m
systemctl is-active xray xray-tcp xray-exporter-xhttp xray-exporter-tcp vector caddy
ss -lntp | grep -E ':(443|8080|8081|8686)\b'
test -S /dev/shm/xray.sock
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
vector validate /etc/vector/vector.toml
```

预期结果：

- `uname -m` 为 `aarch64`；
- Xray、两个 Exporter、Vector、Caddy 均为 `active`；
- 公网只暴露 Caddy `:443`；8080、8081、8686 保持本机监听；
- Xray UNIX socket 存在；
- Caddy 与 Vector 配置校验通过。

查看最近日志时避免输出 token、私钥或完整 VLESS 链接：

```bash
journalctl -u xray --since '15 min ago' --no-pager \
  | grep -Ei 'started|processing connection|received request|invalid padding|error|failed' \
  | tail -100
journalctl -u vector --since '15 min ago' --no-pager \
  | grep -Ei 'billing|snapshot|http|retry|401|403|404|422|5..|error' \
  | tail -100
journalctl -u caddy --since '15 min ago' --no-pager \
  | grep -Ei 'handshake|certificate|reverse_proxy|error|started' \
  | tail -100
```

## 5. VLESS 分段验收

使用控制台生成的当前 VLESS 配置，检查以下字段：

```text
address/host = agent-proxy-selfhost-prod.svc.plus
port         = 443
security     = tls
sni          = agent-proxy-selfhost-prod.svc.plus
type         = xhttp
path         = /split
mode         = auto
```

订阅 URL 生成器必须满足：

1. 不生成 `x_padding=`；
2. 不把旧节点 `tky-proxy.svc.plus` 混入新节点链接；
3. UUID 来自 Accounts/Agent Proxy 的 canonical 配置，不由前端随机生成；
4. `host` 与 `sni` 使用真实节点域名；
5. 修改链接后重新导入客户端，再观察节点端 Xray 日志是否出现真实用户请求。

只看到以下内部探针日志，不算真实用户流量：

```text
proxy/dokodemo: received request for 127.0.0.1:...
app/dispatcher: taking detour [api] for [tcp:127.0.0.1:28080]
```

## 6. Grafana 与计费面板分开验收

### Grafana 实时监控链路

Grafana 选择：

```text
Node = agent-proxy-selfhost-prod.svc.plus
User = admin@svc.plus 或 All
Time = 最近 5 分钟
```

应能看到 `job="xray"`、`transport="xhttp"` / `"tcp"` 以及用户维度上下行 series。该结果证明 Prometheus remote write 链路正常。

### Billing / PostgreSQL 计费链路

计费面板依赖 Accounts 的会话接口：

```text
GET /api/account/usage/summary
GET /api/account/usage/buckets
```

Accounts 以当前会话用户的 canonical UUID 查询 PostgreSQL；Billing 写入的表为：

```text
traffic_stat_checkpoints
traffic_minute_buckets
billing_ledger
account_quota_states
```

因此必须按以下顺序验收：

1. Vector 配置存在 snapshot source 和 Billing HTTP sink；
2. Vector 对 Billing ingest 得到带响应体的成功结果；
3. Billing PostgreSQL 中出现当前用户 UUID 的新分钟桶和 checkpoint；
4. Accounts `/api/account/usage/summary` 返回相同 UUID 的非零 `totalBytes` / `usedBytes`；
5. Portal `/panel` 的用户会话与该 UUID 一致，并显示用量。

Grafana 有数据但 Portal 仍为 `0 B` 时，优先检查：

- Vector 是否只配置了 Prometheus sink，未配置 snapshot -> Billing sink；
- Billing endpoint 是否是生产地址，且 token 鉴权成功；
- Billing 写入的 UUID 是否存在于生产 Accounts `users.uuid`；
- 当前 Portal 会话是否登录了另一个用户或另一套 Accounts 数据库；
- `traffic_minute_buckets` 的最新 `bucket_start` 是否落后当前时间；
- Portal 是否因 Cloudflare Worker 1101 在接口到达前失败。

## 7. 当前遗留项

本次节点和 Grafana 实时监控已验证通过，但计费面板不能仅凭 Grafana 截图判定通过。最后一次浏览器检查曾返回：

```text
Cloudflare Error 1101 — Worker threw exception
```

因此下一步应先确认 `console-serverless-prod.svc.plus` 的 Worker 日志和面板请求是否恢复，再使用生产登录会话读取 `/api/account/usage/summary`。若接口返回成功但仍为零，再转查 Billing snapshot 入库和 UUID 映射；不要通过修改 Grafana 查询或手工写 PostgreSQL 掩盖问题。

## 8. 相关资料

- [Xray Billing / Observability 链路审计](2026-08-02-uat-xray-billing-observability-chain-audit.md)
- [UAT r6 链路收尾记录](2026-08-02-uat-r6-chain-closeout.md)
- [Serverless Billing 动态路由记录](2026-08-21-uat-serverless-billing-dynamic-routing-case.md)
- [Agent Proxy Domain 文档](../domains/agent-proxy/README.md)
