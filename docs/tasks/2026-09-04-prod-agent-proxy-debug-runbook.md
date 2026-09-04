# PROD Agent Proxy 调试与验收 Runbook

> 状态：PROD 七段计量链路已端到端通过；新节点可进入受控切换，旧节点仍需排空
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
| 修复 PR | [`platform-ops-toolkit` PR #538](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/538)，merge commit `edffefabf5941f172c3f7f63076c2947fa7779d4` |
| Daily Snapshot | [run 33881238870](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/33881238870) SUCCESS |
| 实际生产版本 | `v2026.09.04-r8`，源引用为 `daily-build-2026.09.04-r3` |
| PROD Serverless | [run 33881838023](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/33881838023) SUCCESS |
| PROD Agent Proxy | [run 33882404351](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/33882404351) SUCCESS |
| 节点规格 | AWS T4G，ARM64，2C1G，绑定 EIP |
| 当前 EIP | `35.79.83.48` |
| DNS | `agent-proxy-selfhost-prod.svc.plus` 为 A 记录，当前解析到 `35.79.83.48`；节点代理模式为 DNS-only |
| 节点根探针 | `https://agent-proxy-selfhost-prod.svc.plus/` 返回 `Agent Service Plus Node` / HTTP 200 |
| Grafana | 已观察到 `agent-proxy-selfhost-prod.svc.plus`、`admin@svc.plus` 的上下行指标 |
| Accounts / Portal | `admin@svc.plus` 最近 1 小时、24 小时及本月均为 `1.01 MB`，数据源 `postgresql`，统计延迟约 `40 s` |

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

### 3.6 Grafana 有数据、Portal 为零的根因

本次并不是 Xray 没有产生流量，而是计费数据平面存在两个独立断点：

1. PROD 解析到了 `compassvpn/xray-exporter@v0.6.0` 的 metrics-only 构建。它能提供 `/scrape`，所以 Grafana 正常，但没有运行 billing snapshot loop，也没有持续更新 snapshot store；
2. Agent Proxy 使用生产公开域名调用 Accounts identities 与 Billing ingest 时，被 Cloudflare Managed Challenge 返回 HTTP 403。机器到机器请求不应经过要求浏览器交互的边缘路径。

修复后的生产契约为：

- 从 `ai-workspace-xstream/xray-exporter` 解析日期化、不可变的 ARM64/AMD64 daily release；
- XHTTP 与 TCP exporter 都显式设置 `--node-id` 和 `--snapshot-store-path`；
- Accounts identities 和 Billing ingest 使用 GitOps 声明的 Cloud Run machine origin；
- 浏览器、注册语义及用户入口仍使用公开 Accounts 域名；
- PROD 流水线必须运行 `Verify Xray to Billing ingest chain`，且两个 snapshot store 均通过结构校验。

## 4. 节点只读检查

在节点上执行：

```bash
hostname -f
uname -m
systemctl is-active xray xray-tcp xray-exporter-xhttp xray-exporter-tcp vector caddy
ss -lntp | grep -E ':(443|8080|8081|8686)\b'
test -S /dev/shm/xray.sock
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo vector validate /etc/vector/vector.toml
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

## 7. 七段链路的最终验收记录

以下证据来自 `v2026.09.04-r8` 部署完成后的生产只读检查。不要在 Runbook 或流水线日志中打印 VLESS 链接、Bearer token、私钥或完整用户清单。

| 段 | 生产证据 | 常见失败信号 |
| --- | --- | --- |
| Xray | `xray` / `xray-tcp` active；Xray `26.3.27 linux/arm64`；22 个 Accounts identities 已同步；日志出现真实 `proxy/vless/inbound` 并请求 `tcp:speed.cloudflare.com:443` | 只有 `dokodemo` / `127.0.0.1:28080` 表示只有内部 API 探针；`Exec format error` 表示架构包错误 |
| Exporter snapshot | `xray-exporter` 为 `daily-build-2026.09.04-r3-6cbacc...`；XHTTP/TCP 的 `/scrape` 均 HTTP 200；两个 snapshot store 都在持续刷新且各保留 20 个窗口 | metrics-only exporter 虽可让 Grafana有数据，但 snapshot 文件不更新 |
| Vector | `vector` active；配置包含 `xray_snapshot_input` 与 `billing_snapshot_ingest`；PROD 验证 job 通过 | 仅有 Prometheus sink、Billing 401/403/404/5xx、snapshot listener 不可达 |
| Billing | 流水线使用 Vector 同一鉴权配置验证 ingest；空测试 payload 返回业务校验响应而不是边缘 403 或空 200；真实 snapshot 最终形成非零用量 | Cloudflare Managed Challenge 403；鉴权 401；业务服务 5xx |
| PostgreSQL | Portal 明确显示数据源 `postgresql`，非零结果为 `1.01 MB`；目标事实表为 `traffic_stat_checkpoints` 与 `traffic_minute_buckets` | checkpoint 不增长、分钟桶时间落后、account UUID 无法关联 |
| Accounts API | 当前登录用户 `admin@svc.plus` 返回非零小时/日/月汇总，统计延迟约 40 秒；代理 UUID 与新节点 Xray client 同步一致 | `/api/account/usage/summary` 返回零、错误用户、错误数据库或缓存旧值 |
| Portal | `/panel` 显示最近 1 小时、24 小时、本月均为 `1.01 MB`，连接验证完成，运行节点仅下发 `agent-proxy-selfhost-prod.svc.plus` | 页面仍显示 `0 B`、Worker 1101、节点列表混入旧节点 |

Exporter snapshot 中的 `account_uuid` 是 Accounts canonical user UUID；VLESS proxy UUID 只是接入凭据。两者由 Accounts identity 同步完成映射，不能在前端或 Billing 中当作同一个字段使用。

快速复验：

```bash
ssh admin@agent-proxy-selfhost-prod.svc.plus

systemctl is-active caddy xray xray-tcp \
  xray-exporter-xhttp xray-exporter-tcp vector
sudo systemctl show xray-exporter-xhttp -p ExecStart --value \
  | grep -F -- '--snapshot-store-path'
sudo systemctl show xray-exporter-tcp -p ExecStart --value \
  | grep -F -- '--snapshot-store-path'
sudo find /var/lib/xray-exporter -maxdepth 1 -name '*-snapshots.json' \
  -printf '%f %s bytes %TY-%Tm-%TdT%TH:%TM:%TS%Tz\n'
sudo journalctl -u xray --since '15 min ago' --no-pager \
  | grep -E 'proxy/vless/inbound|accepted ' | tail -20
```

验收时还要在已登录的 Portal 中确认：用量非零、数据源为 `postgresql`、统计延迟保持在允许窗口内，且运行节点列表只包含期望的新生产节点。

## 8. 新旧节点对比与切换结论

2026-09-04 生产只读对比：

| 维度 | 旧节点 `tky-proxy.svc.plus` | 新节点 `agent-proxy-selfhost-prod.svc.plus` |
| --- | --- | --- |
| 主机 | ARM64，2C、约 928 MiB | AWS T4G ARM64，2C、约 935 MiB，EIP |
| 核心服务 | Caddy、Xray、双 Exporter、Vector 均 active | Caddy、Xray、双 Exporter、Vector 均 active |
| Xray | `26.3.27 linux/arm64` | `26.3.27 linux/arm64` |
| Caddy / TLS | 配置有效；证书仅覆盖旧域名；仅匹配 `/split/*` | 配置有效；证书覆盖 `*.svc.plus`；匹配 `/split` 与 `/split/*`，并提供受控 exporter 路由 |
| 当前 admin 代理身份 | 当前生产 admin proxy UUID 不在旧配置中 | 当前生产 admin proxy UUID 已同步；Xray 共 22 个 identities |
| Exporter | 2026-08-21 旧构建；启动参数没有 snapshot store；现存文件停留在 2026-08-21/22 | 2026-09-04 daily build；XHTTP/TCP 都启用 snapshot store；文件持续刷新 |
| 实际流量 | 仍观察到历史用户真实 DNS、GitHub、ChatGPT 等请求 | 已观察到真实 VLESS 请求至 `speed.cloudflare.com:443`，并形成计费用量 |
| 计费链 | 旧 snapshot 不再刷新，不能作为当前 PROD 计费基线 | `Xray -> Exporter -> Vector -> Billing -> PostgreSQL -> Accounts -> Portal` 全链通过 |
| Portal 下发 | 不再出现在当前 admin 的运行节点列表 | 当前 admin 只下发该节点，连接验证已完成 |

结论：**新节点已满足切为 PROD 主节点的技术条件，当前 admin 实际上已经完成下发切换；但旧节点仍有历史用户活跃会话，所以本次只批准受控切主，不批准立即销毁旧节点。**

建议切换顺序：

1. 默认策略组和已迁移用户只下发新节点；停止向新用户签发旧节点连接；
2. 保留旧节点 24 小时作为回滚入口，观察旧节点真实 VLESS 请求是否归零；
3. 新节点连续观察期间要求核心服务无重启循环、snapshot mtime 不落后超过 2 分钟、Accounts 统计延迟不超过 120 秒、累计用量单调增加；
4. 若新节点出现 TLS/VLESS/Billing 故障，重新启用旧节点分配，不修改或复用新节点 EIP 来掩盖问题；
5. 旧节点连续 24 小时无待迁移用户流量且用户配置已轮换后，再删除旧节点和对应 DNS/IaC 状态。

当前非阻断技术债：

- 新节点 Vector 日志提示 Billing 与 observability sink 禁用了 TLS certificate/hostname verification，应单独恢复严格 TLS 校验；
- Vector 的 `docker_logs` source 在无 Docker socket 的原生节点上会报连接错误，应按节点运行时条件关闭；
- 旧节点 Vector 的本地 blackbox exporter `127.0.0.1:9115` 不可达，进一步说明它不应继续作为生产可观测性基线；
- Portal 的 free 套餐仍显示 `0 B / 0 B`，这是订阅/配额初始化问题，不影响已修复的流量采集链，但应在全面迁移前单独处理。

## 9. 相关资料

- [Xray Billing / Observability 链路审计](2026-08-02-uat-xray-billing-observability-chain-audit.md)
- [UAT r6 链路收尾记录](2026-08-02-uat-r6-chain-closeout.md)
- [Serverless Billing 动态路由记录](2026-08-21-uat-serverless-billing-dynamic-routing-case.md)
- [Agent Proxy Domain 文档](../domains/agent-proxy/README.md)
- [`platform-ops-toolkit` PR #538：PROD snapshot 与 machine-origin 修复](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/538)
