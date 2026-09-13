# XConnect One 网络设计原则

这份文档提炼了现有 VPS/CPA 网络设计中适用于 XConnect Zero → Gateway →
One 主线的原则。LiteLLM、CPA 和具体业务路由属于上层应用，不属于
XConnect Zero 控制面或 Gateway runtime 的职责。

## 必须保留的原则

### 1. 节点身份不依赖公网 IP

One 和 Gateway 都使用独立的设备密钥、WireGuard 公钥和 Zero 设备凭据。
公网 IPv4 只用于建立 TCP 443 的传输连接或临时 SSH 白名单，不能作为入网
授权条件。单个节点凭据泄露时，只撤销该节点，不共享整个节点池的身份。

### 2. Gateway 执行最小连通策略

Gateway 不只是转发器。它必须根据 Zero 下发的网络、设备和策略，只安装获
授权的 WireGuard peer 与 AllowedIPs；默认拒绝未声明的跨节点访问。

当前 UAT 的最低验收关系是：

```text
One → Gateway overlay address
```

后续如果业务节点需要访问 CPA，应由 Zero 策略显式声明
`LiteLLM → cpa-*` 的最小端口集合，而不是开放整个 overlay 网段互通。

### 3. 稳定名称优先于手工维护的内网 IP 表

Gateway、One 和未来的业务节点应拥有稳定的逻辑节点 ID 与内部名称，例如
`cpa-tokyo.internal`。内部名称由 Zero/Gateway 的节点目录或后续内部 DNS
提供；业务配置不应直接依赖会变化的公网地址。

当前 UAT 固定映射为：

| 角色 | 稳定标识 | 说明 |
|---|---|---|
| Gateway | `TW-XConnect.svc.plus` / `gw-uat-tw-xconnect` | 稳定 relay 入口 |
| One | `observability.svc.plus` / `observability-uat` | 固定 UAT One |

### 4. 网络健康与业务健康分开观测

XConnect 指标至少单独记录：

- 节点注册、签名配置 generation、ACK 与凭据有效期；
- WireGuard peer 的最近握手时间；
- Gateway/One runtime、Xray 和 WireGuard 服务状态；
- overlay ping、指定端口 HTTP/TCP 探针及延迟。

CPA、LiteLLM 或其他业务服务的账号限流、HTTP 错误和 fallback 指标另行
记录。业务请求失败不能直接推断为 overlay 断链。

### 5. 凭证要可轮换、可撤销

短期邀请只负责首次加入；加入后使用设备凭据和签名配置同步。撤销或租约
到期时，Zero 使设备凭据失效并递增网络 generation，Gateway 在下一次同步
移除 peer。长期 Gateway 的 TLS/传输密钥和 One 的私钥只保存在节点受保护
目录或 Vault，不能进入 GitOps、URL、命令参数或 Actions artifact。

## Gateway 的边界

Gateway 是新增节点入网、配置同步和撤销生效的准入变更入口；它不等同于
所有业务流量的单点。已建立的数据面连接可在控制面短暂不可用时继续运行，
但新增、轮换和撤销必须等待 Gateway/Zero 恢复。

## 当前 UAT 适用拓扑

```text
Portal → BFF → Accounts（唯一正式配置源）
                         ↓ signed config / enrollment / policy
          TW-XConnect.svc.plus（独立 Linux Gateway）
                         ↓ WireGuard over VLESS
          observability.svc.plus（独立 Linux One）
```

公网只开放受白名单限制的 TCP 443；WireGuard UDP 51820 不作为公网入口。
`observability.svc.plus` 是既有固定 One，不由 Terraform 或 Spot 生命周期
管理。本次 UAT 流程只负责接入、同步、Gateway peer reconcile、握手、overlay
ping 和临时私网 HTTP 验证，不改变其现有业务服务。
