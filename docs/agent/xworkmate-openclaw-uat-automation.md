# XWorkmate / OpenClaw UAT 自动化边界

## 目标

让部署在 `console.svc.plus` 的 OpenClaw，以及桌面端 XWorkmate APP，都能驱动同一条
UAT 发布与数据验证链路，同时不把 GitHub、Vault、Supabase 或数据库凭据暴露给模型或
插件参数。

## 推荐拓扑

```text
XWorkmate APP plugin ─┐
                      ├─ XWorkmate Bridge / MCP ── GitHub Actions ── UAT serverless
OpenClaw on console ──┘          │                         │
                                 └─ read-only status/probes ─┘
```

- XWorkmate APP 和 OpenClaw 只调用 Bridge 的工具接口；不直接 SSH 到 PROD，也不直连
  Supabase。
- UAT 入口使用编排器注入的 `XWORKMATE_BRIDGE_SERVER_URL`，默认形态为
  `https://bridge-uat.onwalk.net`。`accounts-uat.onwalk.net` 是受用户密码 + MFA 保护的
  轻量 IAM 与多租户管理面；它由 Bridge 代表 APP 访问，不应被误当成 Bridge 本身。
- Bridge 负责认证信息的校验、租户上下文绑定和受限分发。插件只得到 run id、状态和
  脱敏日志摘要；需要访问 Accounts 用户数据时，沿用用户已完成 MFA 的会话/授权，不把
  用户密码或 MFA 秘密交给 OpenClaw、插件或 GitHub Actions。

## 插件工具契约

建议 XWorkmate Harness plugin 和 OpenClaw MCP adapter 复用以下工具（具体 API 名称由
Bridge 实现，不在插件中硬编码 Accounts 内部接口）：

1. `resolve_tenant_context(tenant)`：通过 Bridge 校验当前用户的 MFA 会话，并返回最小
   租户上下文；不返回密码、MFA secret 或长期 token。
2. `get_auth_distribution(tenant, audience)`：由 Bridge 生成目标 audience 的短期认证
   信息，并按租户边界分发给 XWorkmate/OpenClaw 工作流。
3. `trigger_uat_release(tag_ref, migration_strategy)`：仅接受不可变的
   `uat-daily-build-*` tag；自动发布固定传 `accounts_merge`。`replace_public` 必须额外
   要求人工确认，不允许由模型默认选择。
4. `get_job_status(run_id)`：读取 serverless orchestrator 和 reusable migration 的
   job 状态，返回失败步骤与 GitHub Actions 链接。
5. `verify_uat_accounts()`：只读检查 Accounts merge 的 no-op replay、用户接口状态码，
   以及 `/panel/management` 汇总接口是否返回数据。
6. `read_uat_observability(window)`：只读查询日志、指标和 traces；不提供重启、删库或
   修改告警工具。

## 自动化纪律

- 每次自动发布都由 `daily-main-snapshot.yaml` 在 immutable tag 构建完成后触发
  `serverless-orchestrator.yml` 的 `deploy+migrate`；迁移策略显式为 `accounts_merge`。
- 目标 public schema 非空时，Accounts merge 保留 UAT 行并按时间戳合并；只有明确选择
  `replace_public` 并传入确认值时才备份后清理 public。
- 插件应在发布完成后等待迁移 job，再执行真实接口验证；不能把 workflow `success` 当作
  数据展示已恢复的充分证据。
- 任何凭据轮换、Vault policy 修改、生产切流或删除操作都必须脱离模型自动批准流程，
  通过标准 PR/审批完成。
