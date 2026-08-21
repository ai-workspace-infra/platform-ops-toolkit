# UAT Serverless Billing 动态入口验证 Case

日期：2026-08-21  
环境：UAT  
状态：已完成修正并完成 UAT 回归验证。

## 目标与范围

本次验证覆盖 `agent-proxy-vps-uat.onwalk.net` 的完整计费链路。`web-saas` 控制面继续使用 Serverless；其他业务域通过 `cloud_provider` 选择部署形态，当前可运行副本为 `vultr-vps`。调用方不得硬编码 `billing-selfhost-*` 或 `billing-serverless-*`，必须根据服务端解析出的 Accounts/控制面部署形态动态选择 Billing 入口。

## 请求、变更与运行记录

| 项目 | 结果 |
| --- | --- |
| 用户指定快照输入 | `uat-daily-build-2026.08.21-r8` |
| 快照约束 | `r8` 已存在且不可变；合并新修正后，Daily Main Snapshot 必须自动解析为下一修订号（预期 `uat-daily-build-2026.08.21-r9`），不得覆盖 `r8` |
| Edge Gateway 内部服务鉴权 | [PR #19](https://github.com/ai-workspace-services/edge-gateway/pull/19)、[PR #20](https://github.com/ai-workspace-services/edge-gateway/pull/20)，均已合并 |
| 平台动态 Billing 路由 | [PR #464](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/464)，已合并 |
| 远端 `/bin/sh` 兼容修正 | [PR #465](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/465)，已合并 |
| 假绿验证修正与本 Case | [PR #466](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/466)，已合并 |
| Daily Main Snapshot（输入 `r8`，实际解析 `r9`） | [run 32439620009](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32439620009)，成功 |
| 本次 Serverless Orchestrator（`r9`） | [run 32440119703](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32440119703)，成功 |
| 本次 Selfhost Orchestrator（`r9`） | [run 32440534755](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32440534755)，成功 |
| 前次 `r8` Daily Main Snapshot | [run 32437613574](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32437613574)，成功 |
| 前次 `r8` Serverless Orchestrator | [run 32437870330](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32437870330)，重跑后成功；重复触发 [run 32438383639](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32438383639) 亦成功 |
| 前次 `r8` Selfhost Orchestrator | [run 32438806319](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/32438806319)，成功 |

## 现象

- Grafana Xray Dashboard 已能看到 `admin@svc.plus` 的下载/上传速率和累计流量。
- Portal `/panel` 的最近 1 小时、最近 24 小时和本月用量仍显示 `0 B`。
- `agent-proxy-vps-uat.onwalk.net` 应解析到 `167.179.105.137`。

## 正确链路

计费链路：

```text
Xray
  -> xray-exporter :8080/:8081
  -> Vector 127.0.0.1:8686
  -> Billing /v1/ingest/snapshots
  -> PostgreSQL 计费表
  -> Accounts usage API
  -> Portal /panel
```

监控链路独立存在：

```text
Xray
  -> xray-exporter
  -> Vector Prometheus
  -> Observability / VictoriaMetrics
  -> Grafana
```

因此 Grafana 有数据只能证明监控链路正常，不能证明 Billing 已接收快照或 Accounts usage API 已汇总数据。

## 根因

1. `selfhost-orchestrator.yml` 原先把 Agent Proxy 的 `BILLING_SERVICE_BASE_URL`、Vector ingest URL 和验证 URL 固定为 `billing-selfhost-<env>...`。当 UAT 使用 Serverless `accounts-serverless-uat` 控制面时，计费请求仍被送到 selfhost 入口。
2. selfhost Caddy 的未匹配路由可能返回 HTTP 200 空响应，旧验证脚本只排除 `404/000`，把这种响应误判为成功，形成假绿。
3. Edge Gateway 对 `/api/internal/*` 仍执行用户 JWT 门禁，且会移除 `X-Service-Token`；xray-exporter 访问 Accounts identities 时得到 401，快照无法完成账号归属。
4. 验证脚本未携带 Vector 已配置的 Billing Authorization；真实入口返回 401 时旧脚本仍可能因为“有响应体”而报 OK。
5. 远端 Ansible shell 使用 `/bin/sh`，旧脚本中的 `[[ ... ]]` 不可移植，导致大小检查出现 `/bin/sh: [[: not found`。

## 修正内容

- 路由脚本根据已解析的 Accounts/controller URL 动态导出 `billing_service_base_url`：Serverless 控制面使用 `billing-serverless-<env>...`，selfhost 控制面使用 `billing-selfhost-<env>...`。下游 Serverless/Selfhost workflow 和远端验证统一消费该输出。
- Edge Gateway 增加 Vault 注入的内部服务 token：精确匹配 token 的 `/api/internal/*` 请求绕过用户 JWT 门禁，代理前移除调用方 token，再注入受信任 token；无效 token 仍返回 401。
- Vector 链路验证从 `/etc/vector/vector.toml` 读取 `billing_snapshot_ingest` 的 Authorization，使用同一鉴权探针访问动态 Billing URL，不在脚本中保存凭据。
- 验证结果现在严格处理：2xx/3xx 以及带鉴权的 400/422（表示请求已到达业务接口）必须有响应体；401/403、404/405、5xx、000、空响应及未知状态均失败。
- 大小检查改为 POSIX `[ ... ]`，兼容 Ansible 的 `/bin/sh`。

## 现场证据

在 `167.179.105.137` 上验证到：

- `xray-exporter-xhttp.service`、`xray-exporter-tcp.service`、`vector.service` 均为 active。
- `/etc/xray-exporter.env` 的 `ACCOUNTS_BASE_URL` 为 `https://accounts-serverless-uat.onwalk.net`。
- `/etc/vector/vector.toml` 的 Billing sink 为 `https://billing-serverless-uat.onwalk.net/v1/ingest/snapshots`，并配置了 Authorization（凭据未记录）。
- Vector snapshot listener 监听 `127.0.0.1:8686`，Xray exporter 使用 `VECTOR_SNAPSHOT_URL=http://127.0.0.1:8686`。
- 修正前的未鉴权探针得到 `HTTP 401`；该结果证明入口可达但鉴权缺失，不能计为成功。
- 本次 `r9` 回归日志确认 `VECTOR_BILLING_INGEST_URL=https://billing-serverless-uat.onwalk.net/v1/ingest/snapshots`，带 Vector Authorization 的探针返回 `HTTP 422`、243 字节；422 是业务接口对空测试 payload 的校验响应，说明请求已到达正确 Billing 服务，而不是未匹配代理的空 200。

## 最终验证结果

- Daily Main Snapshot 在检测到用户输入的 `uat-daily-build-2026.08.21-r8` 指向旧提交后，自动解析不可变修订 `uat-daily-build-2026.08.21-r9`；未覆盖既有 `r8`。
- Serverless `operation=deploy+migrate` 全部成功，包含 Accounts/Billing/Content、Cloudflare Workers、Edge Gateway、Supabase Accounts merge migration 和 Verify/Summary。
- Selfhost `agent-proxy` 使用同一 `r9` 完成 Vultr 部署、DNS 更新、Agent Proxy status、Vector/xray-exporter 部署及 Xray -> Billing 链路验证。
- 验证脚本现在在正确入口收到 422（带响应体）时通过；401/403、404/405、5xx、000、空响应和未知状态均失败，避免再次假绿。

## 回归步骤与防复发

1. 合并本 PR 到 `main`。
2. 以 `snapshot_tag=uat-daily-build-2026.08.21-r8` 触发 Daily Main Snapshot；脚本发现 `r8` 已存在时自动创建下一不可变修订（预期 `r9`），并将同一 tag_ref 传给 Serverless `operation=deploy+migrate` 与 Selfhost `agent-proxy operation=deploy`。
3. 确认 Serverless 完整控制面部署、Supabase Accounts 迁移/验证、Agent Proxy 注册和 DNS 更新均成功。
4. 在 Grafana 验证监控数据，在 Portal `/panel` 验证 Accounts usage 汇总数据；两者必须分别检查。
5. 后续 workflow 只消费 `billing_service_base_url` 输出，不得重新拼接或硬编码部署形态域名；任何 401/403 或空响应都必须让验证 job 失败。

本记录不包含任何 Vault token、Worker secret 或数据库凭据。
