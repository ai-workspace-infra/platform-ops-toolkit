# UAT 快照部署与统计链路进度（2026-08-02）

## 目标

在不改生产 Xray/Exporter 的前提下，在 UAT 验证两条相互独立的链路：

```text
计费统计：Xray → compassvpn/xray-exporter v0.6.0 → Billing → PostgreSQL → Accounts → Portal
实时观测：Xray → compassvpn/xray-exporter → Vector/Observability → Grafana
```

Exporter 同时提供两类事实来源，但 Grafana/Vector 不成为计费链路依赖，Billing 也不读取观测存储。

## 已完成

### 1. 生产基线只读核验

- 生产节点 `admin@tky-proxy.svc.plus` 上运行的是上游 `compassvpn/xray-exporter v0.6.0` 构建。
- 业务统计在 `/scrape`，标签包含 `dimension="user",target="email"`，Grafana 使用下载/上传累计指标。
- 生产 Xray client 的邮箱与 UUID 已核对；本轮没有修改生产主机、生产 Xray 或生产 Exporter。

### 2. Exporter 基线与发布

- `ai-workspace-xstream/xray-exporter` 已以 `compassvpn/xray-exporter v0.6.0` 为基础合并 PR #6。
- 增加 UAT 可选 snapshot API、Accounts identity 映射、按 canonical UUID/inbound 聚合和本地保留；未启用配置时保留原 `/scrape` 行为。
- 本地验证通过：`go test ./...`、`go test -race ./...`、`go vet ./...`、`git diff --check`。
- 已验证 tag：`v0.6.0-uat.20260802.1`。
- 跨仓追踪 tag 已补齐：`uat-daily-build-2026.08.02-r1` 指向同一 Exporter commit。

### 3. 部署编排

- Playbooks PR #222 已合并：支持 `compassvpn/xray-exporter` 仓库、版本、Accounts endpoint、token 和 snapshot 参数。
- Platform Ops PR #232、#233、#234 已合并：
  - workflow inputs 压缩到 24 个，监听地址按 UAT 自动使用 `0.0.0.0:8080/8081`，非 UAT 保持 loopback；
  - `EXPORTER_SOURCES_JSON` 支持从 Vault 注入；UAT 缺失时使用仅 UAT 的 agent-proxy 双 source 兜底；生产缺失仍严格失败。
- 第一次 UAT workflow 已成功完成 IAC reconcile、节点 bootstrap、PostgreSQL 初始化和 console 观测 agent 部署。

### 4. 跨仓快照

- Actions run：[Daily Main Snapshot #30731104175](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30731104175)。
- `uat-daily-build-2026.08.02-r1` 已完成四组织 tagging/build 汇总。
- Accounts、Billing、Portal/Console、PostgreSQL 的对应 pipeline 均成功。
- GitOps UAT 分支已更新三项业务镜像 pin，并保留远程 Exporter source 配置：
  - `ACCOUNTS_IMAGE=...:uat-daily-build-2026.08.02-r1`
  - `BILLING_IMAGE=...:uat-daily-build-2026.08.02-r1`
  - `CONSOLE_IMAGE=...:uat-daily-build-2026.08.02-r1`

## 当前阻塞与判断

### 已解决：pull-only tag 不一致

首次部署使用 `uat-daily-build-2026.07.31-r3`，但 GitOps 当时 pin 为 `daily-build-2026.08.01`，pull-only CD 正确拒绝了该请求，没有发生错误版本部署。

现在已改用并构建 `uat-daily-build-2026.08.02-r1`，并同步 GitOps UAT pin；下一轮 dispatch 必须使用该 tag。

### 待处理：UAT 观测 Vault 配置

第一次 UAT run 的 Monitor Agent job 报：

```text
Unable to retrieve result for kv/data/CICD/observability because it was not found
```

这只影响 Vector/Observability agent 的配置，不应阻断 Xray → Exporter → Billing → PostgreSQL → Accounts → Portal 计费链路。需要在 UAT Vault 初始化 observability 配置，或在部署编排中为 UAT 增加明确的非生产默认配置；不应把生产 secret 写入 Git。

### 新增观测日志：本地 exporter 未就绪

UAT `agent-proxy.onwalk.net` 的 Vector 日志还出现：

```text
node_metrics: http://127.0.0.1:9100/metrics → HTTP 503
process_metrics: http://127.0.0.1:9256/metrics → timeout > 5s
```

这说明 Vector 已按配置工作，但 node-exporter/process-exporter 尚未就绪、异常或受资源压力影响；它不是 Billing 写入失败。Playbooks 当前 Vector 模板固定采集这两个本地 endpoint，同时把 Xray `/scrape` 作为独立 source。应先检查 `node-exporter.service`、`process-exporter.service` 的 active 状态和本地响应，再判断是否需要调低采集频率或修复 exporter 服务；不要通过关闭 Xray 采集来规避。

### 待验证：服务部署与页面数据

当前第一轮 workflow 仍有 agent-proxy 原生服务 job 在收尾，结束后才能通过并发保护重新 dispatch 新 tag。下一轮需要验证：

1. agent-proxy 的 `:8080/:8081` exporter health、`/scrape` 和受保护 snapshot API；
2. Billing 能从双 source 拉取并按 UUID/email 聚合，写入共享 PostgreSQL 表；
3. Accounts `/api/account/usage/summary` 返回 `totalBytes`、`usedBytes`、`remainingIncludedQuota`、`periodStart`、`periodEnd`；
4. `https://console-uat.onwalk.net/panel/account` 展示非零采集统计和周期配额；
5. Grafana/observability 仅验证实时监控侧指标，不作为计费结果依据。

## 下一步

1. 等第一轮 UAT workflow 收敛，不取消并行中的基础设施操作。
2. 用 `deploy_tag=uat-daily-build-2026.08.02-r1`、`gitops_ref=feature/route-billing-to-remote-exporter` 从 `main` 重新 dispatch。
3. 保持 `xray_exporter_release_repository=ai-workspace-xstream/xray-exporter`、`xray_exporter_version=v0.6.0-uat.20260802.1`。
4. 逐段记录 exporter、Billing、PostgreSQL、Accounts、Portal 的实际响应和数据时间范围。
5. 补充 UAT Vault observability 配置后，再单独验证 Vector/Grafana 实时观测链路。

## 变更边界

- 仅 UAT 验证；不改 `svc.plus` 生产 Xray、生产 Exporter、生产数据库或生产 GitOps 配置。
- Billing 与 Accounts 共用 PostgreSQL，不拆库、不新增计费服务。
- Portal 仅在已有 `/panel/account` 布局上补充统计展示，保留原有功能。
