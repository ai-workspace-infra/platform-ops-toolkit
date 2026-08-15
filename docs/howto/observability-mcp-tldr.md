# Observability MCP TL;DR

## 用途

`observability.svc.plus` 对 Grafana 和 Victoria 数据组件提供只读 MCP
适配器。发布异常时，应直接查询运行证据，而不是仅根据面板截图或 GitHub
Actions 日志推测主机状态。

这些适配器不能部署、重启、编辑仪表盘或修改告警规则。

## 一次性 Codex 配置

在拥有 Codex 配置目录的终端执行；完成后新开一个 Codex 会话以刷新工具清单：

```bash
codex mcp add observability-grafana \
  --url https://observability.svc.plus/mcp/v1/grafana/mcp

codex mcp add observability-metrics \
  --url https://observability.svc.plus/mcp/v1/metrics/mcp

codex mcp add observability-logs \
  --url https://observability.svc.plus/mcp/v1/logs/mcp

codex mcp add observability-traces \
  --url https://observability.svc.plus/mcp/v1/traces/mcp
```

不输出凭据地确认注册状态：

```bash
codex mcp list
```

如果网关后续启用 MCP 认证，将所需 token 配置为环境变量并使用
`--bearer-token-env-var`；禁止把凭据写进命令 URL 或提交到仓库。

## 各 MCP 的问题边界

| MCP | 用途 | 发布诊断示例 |
| --- | --- | --- |
| Grafana | 数据源、仪表盘、告警状态、面板渲染 | UAT 主机是否持续被采集，是否存在可用性告警？ |
| VictoriaMetrics | 时序指标 | `45.77.128.182:443` 是否监听，节点或 Docker 是否不健康？ |
| VictoriaLogs | 主机、容器、服务日志 | Caddy/Docker 是否报告端口绑定、重启、拉镜像或 Compose 收敛失败？ |
| VictoriaTraces | 跨服务调用链 | Agent Proxy 到 Accounts Controller 的请求到达哪里失败？ |

## UAT 故障排查顺序

Web SaaS 与 Agent Proxy 异常时按以下顺序查询：

1. **Metrics：**查看 Web SaaS `45.77.128.182`、Agent Proxy
   `167.179.105.137` 的主机可达性、Docker/容器指标及端口探测。
2. **Logs：**在相同时间窗查看 `web-saas-caddy`、Doco-CD、Docker daemon 与
   `agent-svc-plus` 日志。
3. **Traces：**当 Agent Proxy 无法生成 Xray runtime config 时，跟踪其到
   Accounts Controller 的调用链。
4. **Grafana：**用对应面板对外汇总最终时间线与告警状态。

当前已知故障特征：

```text
web-saas-caddy is running
but Docker publishes no 80/tcp or 443/tcp host port
=> 45.77.128.182:443 connection refused
=> Agent Proxy cannot call Accounts and cannot generate Xray configuration
```

容器 `running` 不是足够证据。切换 DNS 前必须同时确认容器状态与宿主机端口发布/监听。

## 安全边界

- 所有 MCP 适配器保持只读。
- 禁止把 Vault、GitHub、Cloudflare 或 Grafana 凭据粘贴到提示词、URL 或仓库文件。
- MCP 观测结果用于发布决策；实际变更仍必须走标准 GitOps Pull Request。
