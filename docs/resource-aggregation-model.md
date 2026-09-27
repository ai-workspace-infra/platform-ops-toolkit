# UAT / PROD resource aggregation contract

资源聚合必须区分“期望配置”和“运行事实”。GitOps 文件描述期望拓扑，不能作为
云上资源正在运行的 CMDB，也不能单独把资源标记为 `healthy`、`active` 或
`deployed`。

## 两类数据

| 数据层 | 权威来源 | 允许表达 | 不允许表达 |
| --- | --- | --- | --- |
| Desired state | GitOps 声明、工作流输入、发布 tag | 期望 provider、环境、region、plan、service domain、state namespace | 当前 instance ID、当前公网 IP、当前运行状态、实时流量 |
| Observed state | provider API、Cloudflare API、Cloud Run API、Supabase API、DNS 查询、健康检查、workflow run/CMDB artifact | 实际资源 ID/IP、状态、版本、最后观测时间、健康检查结果、流量 | 用 GitOps 声明推断资源已经创建或仍在运行 |

聚合页面和 CMDB 只把 Observed state 作为运行状态来源。Desired state 作为单独的
`declared` 层展示，并通过资源主键关联；缺少对应观察记录时状态必须是
`declared_only`，不能显示为 `running`。

## 环境隔离

所有记录都必须带 `environment`，只允许 `sit`、`uat` 或 `prod`。UAT 和 PROD 的
同名资源、tag、workflow run、IP 和 DNS 记录不得合并。每条观察记录至少包含：

```json
{
  "environment": "uat",
  "provider": "akamai-cloud",
  "resource_key": "svc.plus/uat/akamai/open-platform",
  "observed_at": "2026-09-27T00:00:00Z",
  "status": "running",
  "instance_id": "106021732",
  "public_ip": "45.79.175.119",
  "source": "akamai-api"
}
```

`instance_id`、`public_ip` 和 `observed_at` 只能来自 provider API 或部署运行产生的
CMDB artifact；它们不应回写成 GitOps 的期望值。GitOps 中的 `service_domains` 只
用于关联 DNS/健康检查目标。

## 当前 UAT 对齐基线

- Akamai Cloud：先从 provider API/terraform state 观察六个 namespace；GitOps
  `resources/svc.plus/uat/akamai/*.yaml` 只作为期望配置。
- GCP、AWS、Cloudflare、Cloud Run、Supabase：先显示 `declared_only`，直到对应
  provider 同步器写入带时间戳的观察记录。
- `observability.svc.plus`、`vault.svc.plus`：DNS、HTTPS 健康检查和目标节点
  CMDB 分开记录。
- `jp-xhttp-contabo.svc.plus`：保留为迁移源/旧记录，只有在旧节点配置已移除、
  连续观测窗口无流量且 DNS 清理步骤成功后，才允许标记为 `retired`。

## 状态计算

推荐状态优先级：

1. `retired`：已完成迁移清理并确认 DNS 删除。
2. `running` / `degraded` / `stopped`：有近期 Observed state。
3. `declared_only`：只有 GitOps 声明，没有近期观察记录。
4. `unknown`：声明和观察都不存在或数据过期。

GitHub Actions 的 `daily-snapshot-summary-<environment>` artifact 只能作为发布流水
线观察记录，不能替代 provider CMDB。环境总览需要同时显示 desired ref、observed
source 和 `observed_at`，避免把“GitOps 有声明”误解成“云上资源正在运行”。
