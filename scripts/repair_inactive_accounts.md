# 修复 users.active = false 的账号

**TLDR** —— 账号能登录但每个后续请求都 403 `account_suspended`，是注册时漏写 `Active`
导致 `users.active = false`。先跑不带 `--apply` 的一次看 diff，确认无误再加 `--apply`。

```bash
# 1. 看会改什么（只读）
./scripts/repair_inactive_accounts.sh --env prod --email someone@example.com

# 2. 确认 diff 只有 active: f → true 之后
./scripts/repair_inactive_accounts.sh --env prod --email someone@example.com --apply
```

`--apply` 会要求你**手动输入环境名**（输 `prod`，不是 `y`）才继续。

## 优先用 --email 定点修复

`--email` 可重复，只修指定账号。比全量修复安全，而且**不会过期**——见文末"时效性"：
全量修复的前提会随 accounts#153 上线而失效，定点修复始终合法。

不带 `--email` 时，所有 inactive 账号都是候选，此时**必须**用 `--exclude-email` 排除
应用商店审核账号——那是全代码库唯一会**故意**把用户置为 inactive 的地方
（`cmd/accountsvc/main.go`，配置关闭时停用）。不排除会被误激活。

## 这是什么故障

`register` 构造 `store.User` 时没有设置 `Active`，而 `postgresStore.CreateUser` 总是
显式写这一列，所以 schema 的 `DEFAULT TRUE` 永远不生效，新账号落库即 `active = false`。

`login` 不读 `users.active`，`auth.RequireActiveUser` 读。用户侧表现为：

```text
POST /api/auth/login     200   Set-Cookie: xc_session=…
GET  /api/auth/session   403   account_suspended
GET  /api/auth/session   403
```

登录成功、Cookie 正常、页面开始渲染，然后每个请求被拒。代码已在
[accounts#151](https://github.com/ai-workspace-services/accounts/pull/151) 修复；
本脚本修的是**修复到达该环境之前**已经写坏的行。

## 前置

```bash
brew install libpq && brew link --force libpq   # 提供 psql
vault login                                      # 脚本从 Vault 取库凭据
```

依赖：`vault` `jq` `psql` `python3`。凭据读自 `kv/<env>/serverless/supabase`，
**脚本内不含任何明文口令，也不会打印它们**。

## 安全设计

| 机制 | 作用 |
| --- | --- |
| 默认只读 | 不加 `--apply` 只报告，不写入 |
| `--apply` 需输入环境名 | 疲劳时 `y` 是肌肉记忆，`prod` 是刻意行为；`--yes` 供已核对过的重跑 |
| `--email` 定点 | 只修指定账号，把影响面收敛到一行 |
| 两段式 | `--apply` 只更新**第一阶段列出并经你核对的那批 uuid**，而非重跑一遍条件 |
| `--max-rows`（默认 50） | 超限直接拒绝：这个量级就不只是注册 bug，先查清楚 |
| 事务内前后快照对比 | 除 `active` 外任何字段被改动 → `RAISE EXCEPTION` 回滚，并报出是哪些字段 |
| 行数 guard | 实际激活数与核对数不符 → 回滚 |
| uuid 形状校验 | uuid 是唯一被拼进 SQL 的值 |

两段式的意义：核对与执行之间如果有新的坏行出现，它**不会被顺带改掉**——留给下一次运行。

前后快照对比的意义：把"只改 active"从一句承诺变成数据库自己校验的不变量，
能兜住触发器、列默认值、`ON UPDATE` 规则这类读代码时看不见的东西。
快照会剔除 `password` 与 `mfa_totp_secret`，密文不进临时表也不进输出。

## 输出长什么样

```text
==> prod: accounts at aws-0-ap-southeast-1.pooler.supabase.com (user postgres.xxx, db postgres)
    excluding: review@example.com

Accounts currently inactive:
 uuid | email | username | created_at | updated_at

Field-level diff this repair would produce:
       email        | field  | before | after
--------------------+--------+--------+-------
 someone@…          | active | f      | true
(no other column is written -- enforced in the transaction, see below)

==> 2 account(s) would be reactivated
==> dry run. Re-run with --apply to reactivate exactly the accounts listed above.
```

加 `--apply` 后会多打印一段 `Applied diff:`——那是**实际发生的**变化，由前后快照算出，
不是预测。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 无需修复，或修复完成 |
| 1 | 拒绝执行（guard 触发、参数非法、连接失败） |
| 2 | 缺少依赖 |

## 时效性：这个脚本会过期

[accounts#153](https://github.com/ai-workspace-services/accounts/pull/153) 上线后，
`POST /admin/users/:userId/activate` 与 `.../deactivate` 可用，`active = false` 就成了
**管理员可以合法设置的状态**。届时：

- 这个脚本的"凡 false 皆为 bug"前提不再成立，**不要再全量跑**
- 修单个账号改走 admin API，变更会落在正常的鉴权与审计路径上

换句话说：这是一次性的历史数据订正工具，不是常备运维手段。

## 验证

修完之后，受影响用户的 `/api/auth/session` 应当返回 200 而不是 403：

```bash
gcloud logging read 'resource.type="cloud_run_revision"
  AND resource.labels.service_name="prod-accounts"
  AND httpRequest.requestUrl=~"/api/auth/session"' \
  --project=xworktech --limit=20 --freshness=10m \
  --format='value(timestamp,httpRequest.status)'
```

## 相关

- `ai-workspace-services/accounts` → `docs/architecture/auth-gates-and-rate-limits.md`
  —— 这次事故暴露的闸门与限流设计问题，以及发布顺序（**数据修复必须早于 login 开始判定 Active**，
  否则受影响账号会从"能登录但做不了事"变成"完全登不进去"）
