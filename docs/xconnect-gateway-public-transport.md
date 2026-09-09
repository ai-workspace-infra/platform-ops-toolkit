# XConnect Gateway 公网安全传输入口

XConnect Gateway 的公网入口只承载受保护的 VLESS 传输，不承载控制面，也不
直接暴露 WireGuard。

## 当前 UAT 基线

```text
受控节点 WireGuard
  → 本机外部 Xray UDP relay（127.0.0.1:51830）
  → Gateway TCP 443 / VLESS + TLS
  → Gateway 本地 WireGuard UDP 51820
  → XConnect 私网
```

安全组只允许显式传入的受控节点公网 IPv4 `/32` 访问 Gateway TCP `443`。
`22/TCP` 是独立的临时运维白名单；`8443/TCP` 仅保留给同一实验网络内的
受控客户端；`51820/UDP` 不加入公网安全组。

工作流 dispatch 输入 `gateway_transport_ingress_cidrs` 只在本次运行中生效，
用于处理 NAT 出口变化，不写入 GitOps。空值表示关闭外部传输入口。输入最多
两个唯一的规范 IPv4 `/32`，不接受 IPv6、宽范围网段或 `0.0.0.0/0`。

当前 Gateway v0.1.4 的 signed-config 和 runtime 只实现
`vless-tls-xudp`/TCP `443`。后续扩展应新增 transport profile，而不是改变
WireGuard 的本地 `51820/UDP` 边界：

| profile | 默认端口 | 状态 |
|---|---:|---|
| `vless-tls-xudp` | 443/TCP | 当前 UAT 基线 |
| `vless-xhttp` | 443/TCP | 后续扩展，需 signed-config/runtime 同步支持 |
| `vless-reality` | 1443/TCP | 后续可选入口，默认关闭 |

XHTTP 或 Reality 所需的路径、SNI、证书和私钥必须由受信控制面/Vault 注入，
不能进入 GitOps、公开 handoff 或 Actions 日志。启用 `1443` 前必须同时完成
Gateway 配置生成、One 客户端 profile 选择、IaC TCP 规则和精确端到端验证。
