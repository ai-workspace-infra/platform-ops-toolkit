# UAT agent-proxy r3 / r4 链路调试记录

> 记录时间：2026-08-02（Asia/Shanghai）  
> 范围：UAT only；本次没有修改生产资源，也没有操作生产 DNS 或 DNS 自动流程。  
> 目标链路：`agent-proxy Exporter -> billing-uat.onwalk.net -> Billing -> PostgreSQL -> Accounts -> Portal`

## 结论

`platform-ops-toolkit` workflow run [30742827471](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30742827471)
的直接根因是 `agent.svc.plus` 源码仓库没有
`uat-daily-build-2026.08.02-r3` ref。原生部署在
`roles/vhosts/agent-svc-plus/tasks/main.yml:73` 的 Git checkout 处失败：

```text
Failed to checkout uat-daily-build-2026.08.02-r3
error: pathspec 'uat-daily-build-2026.08.02-r3' did not match any file(s) known to git
```

这不是 TLS、Vault 证书、PostgreSQL 初始化或 Billing 业务代码错误。失败前已成功完成
基础设施、两台主机 bootstrap、Web SaaS PostgreSQL 初始化、Web SaaS 部署、两个
Monitor Agent 部署和 Web SaaS observe；Agent Proxy native services job 失败，后续
DNS observe job 被跳过。

## GitHub / 构建状态

### r3 失败 run

| 项目 | 证据 |
| --- | --- |
| Run | [30742827471](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30742827471) |
| HEAD | `ae8d49ec8cc1c49957bf1033b8dbf5bbae37e3aa` (`main`) |
| 成功 | Provision、GitOps tag update、两台 bootstrap、PostgreSQL init、Web SaaS deploy、两台 Monitor Agent、Observe Web SaaS |
| 失败 | [Deploy Agent Proxy Services job](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30742827471/job/91483920186) |
| 跳过 | Switch DNS Traffic & Observe；本次没有执行 DNS 切换 |

### r4 snapshot / tags

Services 侧 r4 已可寻址并有 release manifest：

- `ai-workspace-services/accounts` → `41d25d20a147c40aa4f5988cb37403677b28caa3`
- `ai-workspace-services/billing-service` → `8be07e1fb88c6a383b6954aa8971aab77f9aa71f`
- `ai-workspace-services/docs` → `75ba82ae2eacef6365d8e0e74be48df272d60c44`
- `ai-workspace-services/portal` → `2fcc5c862e001563c819c77c38de7589da0e0907`
- `ai-workspace-services/postgresql.svc.plus` → `31c165f23ba5d9d44b3300c717f35d8eab4d452f`

Exporter 的 UAT 构建也存在：`ai-workspace-xstream/xray-exporter`
`v0.6.0-uat.20260802.1`，release assets 包含 Linux amd64/arm64 等构建。

在本次复核期间，r4 source tag 已补上：

- `ai-workspace-xstream/agent.svc.plus`（GitHub API 的 `x-evor/agent.svc.plus` 已重定向到此仓）
  的 `uat-daily-build-2026.08.02-r4` → `1b5f4f2a2176323c2af77da72dfaae045ff201fa`。
- [修复后的 Daily Main Snapshot run 30743673976](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30743673976)
  已 SUCCESS；日志确认跨组织仓库被过滤，r4 tag/build 汇总不再因 matrix token 失败。
- `agent.svc.plus` 没有以 `uat-daily-build-*` tag 自动生成 GitHub Release（其 release workflow
  只由 `main`/`v*` push 发布）；这不阻断本 UAT playbook，因为本次 workflow 明确设置
  `agent_svc_plus_build_on_target=true`，目标主机从 source tag checkout 后本地构建。

### r4 snapshot run

[Daily Main Snapshot run 30743427197](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30743427197)
在 `ai-workspace-services` 和 `ai-workspace-xstream` 两个 matrix job 失败。日志显示：

```text
Repository ai-workspace-xstream/agent.svc.plus is outside the selected organizations.
```

原因是 workflow dispatch 传了跨组织的完整 `SNAPSHOT_REPOS`，每个 matrix job 只持有本组织
GitHub App token，却把完整列表交给了单组织脚本。该逻辑已经由
[platform-ops-toolkit PR #240](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/240)
修复并合入当前 `main`（`7220274bd748b9847d42e2bd860a25c1eaf5b1b0`）：非本 matrix 组织的仓库
现在会被过滤，不会让 tag/build job 因跨组织列表直接失败。不要在本记录中重复提交同一修复。

## GitOps 状态

[gitops PR #133](https://github.com/ai-workspace-infra/gitops/pull/133) 已于
2026-08-02 18:23:09（Asia/Shanghai）合并到 `main`，merge commit 为
`bf592ac045f1f4323e49017a785771bc4cafec70`，head 为
`db85d9b964843a96e507eee441c8b1672f7a7bc7`。变更为：

```text
ACCOUNTS_IMAGE=...:uat-daily-build-2026.08.02-r4
BILLING_IMAGE=...:uat-daily-build-2026.08.02-r4
CONSOLE_IMAGE=...:uat-daily-build-2026.08.02-r4
```

该 PR 的 `Sec QA Gate (gitleaks)` 和 `Verify declared images exist` 均 SUCCESS；合并本身不证明
Agent Proxy source checkout、目标机编译或 Agent heartbeat 已成功。

## UAT 可验证探针

只做了公网只读查询，没有改 DNS：

| 探针 | 结果 | 解释 |
| --- | --- | --- |
| `accounts-uat.onwalk.net` A | `167.179.64.91` | 当前 UAT Web SaaS 主机可达 |
| `console-uat.onwalk.net` A | `167.179.64.91` | 当前 UAT Web SaaS 主机可达 |
| `agent-proxy.onwalk.net` A | `167.179.105.137` | 当前 UAT Agent 主机地址可解析 |
| `billing-uat.onwalk.net` A | 无记录 | 当前没有可验证的 Billing 公网入口；没有执行 DNS 补录 |
| Accounts `/healthz` | HTTP 200，`{"status":"ok"}` | Accounts 进程存活 |
| Accounts `/api/ping` | HTTP 200，但 `image/tag/commit/version` 均为空 | 不能证明 r3/r4 镜像身份已注入 |
| Accounts `/api/account/usage/summary` | HTTP 401，`session_token_required` | 无会话的公开探针，不能证明账户用量读路径 |
| Console `/` | HTTP 200 | Portal/Console 页面可达；页面 release meta 仍显示 `daily-build-2026.08.01` |
| Agent Proxy `:443` | TLS handshake `SSL_ERROR_SYSCALL` | 与 native agent-proxy job 未完成一致，不能验收 Exporter/Agent |

因此当前不能声称 `Exporter -> Billing -> PostgreSQL -> Accounts -> Portal` 已端到端通过。
Web SaaS observe 的 job 为 SUCCESS，但该次 delegated job 的 `observe_urls` 为空，且未覆盖
Billing r3/r4 runtime identity、Exporter snapshot window 或 authenticated Accounts usage summary。

## 最小修复步骤

1. 复核 r4 五个 web-saas release manifest、agent source tag、Exporter
   `v0.6.0-uat.20260802.1` 均可从 CI/目标主机寻址。
2. 使用显式 `deploy_tag=uat-daily-build-2026.08.02-r4` 重跑 UAT application deployment，
   保持 `confirm_dns_switch=false`；复用现有 UAT state，不执行 DNS 切换自动流程。
3. 先验收 Agent Proxy：`caddy`、`agent-svc-plus`、`xray`、`xray-tcp`、两个 Exporter
   unit 为 active/enabled；再验证 `/v1/snapshots/window` 可被 Billing 从内部/受控地址读取。
4. 验收 Billing `/api/ping`、`/healthz`、`/v1/status`，确认 PostgreSQL 的
   `traffic_minute_buckets` / `billing_ledger` 有新增事实；使用 UAT 测试账号验证 Accounts
   authenticated `/api/account/usage/summary`，最后核对 Portal 页面。
5. GitOps PR #133 已合并；待上述链路通过后，再以实际 runtime identity 和数据库事实确认该
   merge commit 的 UAT 部署结果。

## 阻塞项

- **P0：r4 source tag 已存在，但尚未有使用 r4 的成功 UAT native Agent Proxy deploy**；需重跑并
  验证目标机本地构建、systemd、Exporter 和 Agent heartbeat。
- **P1：billing-uat.onwalk.net 无 DNS**；本次不自动补录，需由环境负责人明确入口设计和 DNS
  变更窗口后再处理。该阻塞不应通过修改生产 DNS 绕过。
- **P1：现有公网 Accounts `/api/ping` 与 Console release meta 未显示 r3/r4**，说明当前公网
  UAT 仍不能作为 r4 运行时证明。
- **P1：没有 authenticated UAT 测试账号/会话证据**，Accounts usage 和 Portal 配额页面尚未
  验收。
