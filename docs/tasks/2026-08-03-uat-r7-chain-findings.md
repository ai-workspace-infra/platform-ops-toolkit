# UAT r7:计费链路实勘与两处源头修复

延续 [2026-08-03-uat-r6-final-handoff.md](./2026-08-03-uat-r6-final-handoff.md)。r6 交接文档把 Portal 用量为 0 归因于 Vector 渲染时序竞争;本轮上机实勘发现**该竞争已被 playbooks#246 修复并部署,当时的两条症状已不成立**,真正的阻塞是另外两个,且其中一个正在悄悄危及 accounts。

## 1. r6 文档中已失效的结论

r6 记录的两条:

- `/etc/vector/vector.toml` 只有 `internal_metrics` / `node_metrics` / `process_metrics`,没有 8080/8081 的 Xray Exporter scrape
- Vector 没有监听 `127.0.0.1:8686`,exporter 每分钟推送被拒

实勘(agent-proxy,r6 部署之后):

```
[sources.xray_xhttp_metrics]     ← 已渲染
[sources.xray_tcp_metrics]       ← 已渲染
[sources.xray_snapshot_input]    ← 已渲染
[sinks.billing_snapshot_ingest]  ← 已渲染

LISTEN 127.0.0.1:8686  vector
LISTEN *:8080          xray-exporter
LISTEN *:8081          xray-exporter
```

**结论:渲染竞争已修复。** 排查这条链路时不要再从 r6 的这两条症状出发。

## 2. 阻塞 A:数据库角色密码漂移(最根本)

### 现象

`web-saas-billing` 每小时(SuspendSyncer 扫描周期)报:

```
Failed to list arrears accounts component=suspend_syncer
err="... failed SASL auth: FATAL: password authentication failed for
user \"account_user\" (SQLSTATE 28P01)"
```

`web-saas-accounts` 表面完全正常,持续返回 200。

### 关键判断:accounts 只是"看起来"正常

- 两个容器持有的密码**完全相同**(sha256 前缀一致、长度一致)
- 该密码走 scram 路径的失败方式,与故意输入错误密码**完全一致**
- accounts 靠**启动时建立的连接池**存活;一旦重启或需要新建连接,会与 billing 一样全面失败

即:数据库中 `account_user` 的真实密码,与两个服务持有的密码不一致。billing 只是因为有定时任务会周期性开新连接,才率先暴露。

### 排查中的一个陷阱

首次验证时,在 postgres 容器内用 `-h 127.0.0.1` 连接**成功**,一度得出"密码正确"的错误结论。原因是 `pg_hba.conf`:

```
host all all 127.0.0.1/32   trust          ← 本地免密, 验证不到密码
host all all all            scram-sha-256  ← 服务经 stunnel 走的是这条
```

**验证凭据必须走非 127.0.0.1 的地址**(例如容器自身的 172.19.0.2),否则 trust 规则会让任何密码都通过。

### 源头

`playbooks/create_databases_and_users.yml` 的密码解析顺序是 `Env > Vault > 自动生成`,而自动生成的值:

- 不会写回 Vault(该文件没有任何 vault write)
- 不会传给应用容器 —— 容器的 `ACCOUNT_DB_PASSWORD` 来自部署侧(Vault)

所以只要 Vault 读取返回空(token 缺失 / 路径不对 / 键不存在),`4f48d27` 引入的 reconcile 任务就会把**正在使用的**角色密码改成一个只有那次 run 知道的随机值。

时间线上这是一次**修复引入的退化**:

- reconcile 之前:CREATE ROLE 被跳过,密码只是「不同步」,库里保持原值
- reconcile 之后:每次部署**主动**把一个本来能用的环境改坏

且现象有延迟——连接池里的旧连接还能用一段时间,要等下次新建连接才暴露。

### 修复

[playbooks#248](https://github.com/ai-workspace-infra/playbooks/pull/248):

- 给密码解析结果打 `source` 标记(`env`/`vault`/`generated`)
- reconcile 前若发现「**已存在的角色 + 自动生成的密码**」,列出角色名后**硬失败**
- `CREATE ROLE` 分支不受影响(新角色没有旧消费者持有密码,生成是安全的)
- Vault 读取是 `failed_when: false`、失败完全静默,补一条说明性告警

**注意:该 PR 只阻止再次改坏,不会自动修复已漂移的环境。** 存量环境需人工把角色密码对齐到容器当前持有的值(对齐后两个服务无需重启即可恢复):

```bash
pw=$(docker inspect web-saas-billing --format '{{range .Config.Env}}{{println .}}{{end}}' \
     | grep '^DATABASE_URL=' | sed -E 's#.*://[^:]+:([^@]*)@.*#\1#')
docker exec -i web-saas-postgresql psql -U postgres -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE account_user WITH PASSWORD '$pw';"
```

验证(必须走非 127.0.0.1 地址):

```bash
docker exec -e PGPASSWORD="$pw" web-saas-postgresql \
  psql -h 172.19.0.2 -U account_user -d account -tAc "select current_user"
```

## 3. 阻塞 B:Vector → Billing 的 400

### 现象

Vector 的 billing sink 持续重试并全部丢弃,20 分钟内 **127 条**:

```
Not retriable; dropping the request. reason="Http status: 400 Bad Request"
Events dropped ... reason="Service call failed. No retries or retries exhausted."
```

快照一条都没进库,因此 `traffic_minute_buckets` / `billing_ledger` / `account_quota_states` 全无变化,Portal 显示 `0 B`。

### 定位方法

Billing 的 `ingestSnapshot` 只有一条 400 路径(JSON 解码失败);鉴权失败是 401,DB 失败是 422。所以 400 一定是解码问题,与阻塞 A 无关。

### 根因

处理器直接把 body 解进单个 `model.Snapshot`,只接受裸对象;而 Vector 的 http sink 会批量发送、对 json codec 发出 **JSON 数组**。离线确证旧解码器遇到数组的报错是:

```
json: cannot unmarshal array into Go value of type model.Snapshot
```

与 sink 收到的 400 完全对应。该 framing 是**扇出这一跳的部署细节**,不属于服务契约。

### 修复

[billing-service#28](https://github.com/ai-workspace-services/billing-service/pull/28):同时接受裸对象、JSON 数组、换行分隔多对象;并让 400 带上有界的 body 摘要(此前只回 `invalid snapshot`,发送方无从判断自己发的是什么编码,这正是本次要靠上机排查才定位的原因)。

## 4. 已自愈:exporter ↔ xray 端口

早先日志中的 `dial tcp 127.0.0.1:18080: connect: connection refused` 来自**旧进程**(pid 24954)。18:53:55 服务重启后,unit 使用的是正确的 `-e 127.0.0.1:28080`(xray 的 api inbound 确实监听 28080,tcp 实例 28181),重启后零错误。

排查时注意区分 journal 中重启前后的进程 pid,否则会把已修复的问题当作现存问题。

## 5. 验证链路的正确顺序

不要从"绿色的部署流水线"推断计费链路可用。逐跳验证:

```
1. xray api 端口在监听        ss -lntp | grep -E ':(28080|28181)'
2. exporter 无采集错误        journalctl -u xray-exporter-xhttp --since -5min | grep -c level=error
3. vector 在监听 8686         ss -lntp | grep :8686
4. vector→billing 无 400      journalctl -u vector --since -10min | grep -c "400 Bad Request"
5. PG 有新行                  select count(*), max(bucket_start) from traffic_minute_buckets;
6. Accounts 汇总非 0          GET /api/account/usage/summary
7. Portal 显示非 0            /panel/account
```

第 5 步是分水岭:前四步只证明传输通,只有 PG 出现新行才说明计费真正发生。

## 6. 关联

| 项 | 位置 |
|---|---|
| r6 交接(部分结论已失效,见 §1) | [2026-08-03-uat-r6-final-handoff.md](./2026-08-03-uat-r6-final-handoff.md) |
| 密码收敛源头修复 | [playbooks#248](https://github.com/ai-workspace-infra/playbooks/pull/248) |
| ingest framing 修复 | [billing-service#28](https://github.com/ai-workspace-services/billing-service/pull/28) |
| 多 inbound 聚合(同一链路的前置修复) | [billing-service#24](https://github.com/ai-workspace-services/billing-service/pull/24) |
| Vector 渲染时序(已修复并部署) | [playbooks#246](https://github.com/ai-workspace-infra/playbooks/pull/246) |
