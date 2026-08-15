# UAT-only DNS 自动更新审计与实现记录

## 范围

审计 `platform-ops.yaml` 的 `confirm_dns_switch`、路由脚本和 Cloudflare DNS 脚本，目标是为以下 UAT 入口提供安全、可重复的 DNS 更新：

- `billing-uat.onwalk.net`
- `console-uat.onwalk.net`
- `accounts-uat.onwalk.net`

本任务不执行 Cloudflare API 写操作，不修改生产 `svc.plus` 流量。

## 初始审计结论

1. 现有 `switch_dns` job 使用 `confirm_dns_switch` 作为最后流量门，并绑定 `environment: production`；它调用通用 `playbooks/update_site_dns.yml`，记录集合来自 inventory/CMDB，范围不固定为这三条 UAT 记录。
2. 现有脚本允许将 `target_domain_base` 传入 playbook。playbook 默认变量和通用 role 的默认 zone 都是 `svc.plus`，虽然 workflow 通常注入目标 zone，但缺少 UAT-only 的硬性边界。
3. 现有 role 会先删除同名记录再创建目标记录；重复执行最终状态可收敛，但每次都会产生删除/创建副作用，不适合作为最小 UAT 自动更新流程。
4. 本次新增流程必须独立于生产切流 job，固定 zone 为 `onwalk.net`，固定记录名为上述三条，IP 只能来自本次 CMDB 中唯一的 `web_saas` 主机。

## 实现设计

- 新增显式 `uat_dns_update` workflow input，默认 `false`；UAT `run_full_stack` 自动选择该安全路径。
- 路由脚本验证 `uat`、`onwalk.net` 和包含 `web-saas` 的目标域；UAT 不允许继续通过旧 `confirm_dns_switch` 触发通用 DNS 切流。
- 新 job 只读取 UAT Vault role 注入的 DNS token，调用仓库内 `.github/scripts/platform-ops/dns/platform-ops_uat_dns_reconcile.sh`。
- 脚本固定三条记录，先读取 zone/record，已有唯一记录则 PUT 更新、删除多余同名记录；目标一致时不写 API；不存在时 POST 创建。
- 脚本拒绝非 `onwalk.net` zone、非 UAT 目标和不明确的 CMDB web-saas 主机，避免误切 `svc.plus`。

## 当前状态

- [x] 审计现有 workflow、路由、Cloudflare 脚本与 playbook role
- [x] 选定 UAT-only 独立 job + 幂等 upsert 方案
- [x] 实现与本地测试
- [x] 提交并创建 PR（draft PR #242）

## 验证记录

- `bash -n`：路由脚本和 reconciler 通过。
- workflow YAML：Ruby YAML parser 通过。
- 路由正例：`uat + onwalk.net + web-saas` 输出 `uat_dns_update=true`、`confirm_dns_switch=false`。
- 路由负例：`uat_dns_update=true + svc.plus` 失败；UAT 旧 `confirm_dns_switch=true` 失败。
- mock Cloudflare API：覆盖创建、更新、重复记录清理，且未产生任何 `svc.plus` 请求。
- 第二次 mock 执行：三条记录均 unchanged，零 POST/PUT/DELETE。

所有验证均使用本地 mock 或静态检查，未提供或调用真实 Cloudflare DNS 凭据。

## 交付

- 分支：`feature/uat-only-dns-auto-update`
- 提交：`feat(uat): add fixed-record DNS reconciliation`
- PR：`https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/242`
- 状态：等待 review/merge；本任务未执行 Cloudflare DNS 变更。
