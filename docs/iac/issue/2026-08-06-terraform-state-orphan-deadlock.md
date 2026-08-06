# 案例：Terraform state 里的孤儿实例让 provision 永久卡死（2026-08-06）

## TL;DR

UAT 的 `platform-ops` 流水线在 provision 阶段连续失败，且**重跑不会自愈**：
plan 的 refresh 阶段直接报 `{"error":"instance not found","status":404}`，
第一个 job 就红，后面 11 个 job 全部跳过。

根因是三个独立缺陷串成的一条链，每一个单独看都"只是偶发"：

1. vultr provider 在实例创建后立刻设置备份计划，撞上 Vultr 侧的竞态而失败
   —— 但实例已经建出来、ID 已经写进 state，留下一条**半成品记录**；
2. 那台机器消失后，provider 的 Read 不把 404 当作"资源已消失"而是直接抛错，
   于是 state 里的孤儿 ID 让**之后每一次 plan 都硬失败**，唯一出路是有人手工
   `terraform state rm`；
3. 更早一次 `destroy` 打在了空 workspace 上，输出 `0 destroyed` 并**以成功
   退出**，机器照常计费而流水线全绿，把问题又藏了几个小时。

修复分两个 PR：[iac_modules#232](https://github.com/ai-workspace-infra/iac_modules/pull/232)
（消除竞态）、[platform-ops-toolkit#272](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/272)
（state 对账 + destroy 作用域断言 + 备份对账）。

本文档的重点在"如何避免"——这三条都不是 Vultr 特有的，任何"有远端真实资源 +
本地状态记录"的系统都会复现。

## 背景

- `platform-ops.yaml` 的 job 0（`Prepare | profile + infra`）负责渲染
  Terraform、init、plan/apply/destroy，并产出 CMDB 作为后续所有部署 job 的
  唯一 inventory。**它红了，整条流水线就没有下文。**
- state 存在 S3 兼容后端，按 `<env>/<cloud>/<project>/<profile>.tfstate`
  分片，workspace 名与之一一对应。
- 相关 profile：`uat` + `web-saas + agent-proxy` →
  workspace `uat-vultr-vps-platform-ops-toolkit-web-saas-agent-proxy`。

## 时间线

全部发生在 2026-08-06（UTC），同一个 UAT 环境：

| 时间 | run | 动作 | 结果 |
|---|---|---|---|
| 03:09 | [31067359006](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31067359006) | destroy，`web-saas + agent-proxy` | `No objects need to be destroyed` —— 此时 state 确实是空的 |
| 04:39 | [31071358398](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31071358398) | deploy | apply 成功建了 2 台（`b88e1017` / `56d18492`），后续部署步骤失败 |
| 07:31 | [31075932843](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31075932843) | deploy | **provider 崩溃**：`terraform-provider-vultr_v2.32.0 plugin crashed`，`nil pointer dereference` |
| 07:37 | [31081666778](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31081666778) | destroy，`all` | **假绿**：路由到 `...-web-saas`（不含 agent-proxy），`0 destroyed`，退出码 0 |
| 08:00 | [31082261506](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31082261506) | deploy | 建出 `e6820ea3` / `0f41a228`，随后 `error setting backup schedule: {"error":"Invalid instance-id.","status":404}` —— apply 失败，**但 ID 已进 state** |
| 14:40 | [31085433584](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31085433584) | deploy | plan 的 refresh 撞两次 404，`Planning failed`；此后每次重跑都一样 |

注意 07:37 那一格：**它是绿的**。如果当时有人看一眼"destroy 到底删了几台"，
后面那 7 个小时的排查根本不会发生。

## 根因链

### 第 1 层：创建期竞态往 state 里塞半成品记录

**现象**：apply 报 `error setting backup schedule: {"error":"Invalid
instance-id.","status":404}`，但去 Vultr 控制台看，实例是**建出来了**的。

**根因**：provider 的 `resourceVultrInstanceCreate` 在实例 `status=active`
之后紧接着调 `POST /v2/instances/{id}/backup-schedule`：

```go
d.SetId(instance.ID)                                    // ← ID 已经进 state
_, err = waitForServerAvailable(ctx, d, "active", ...)  // 等 active
if backups == "enabled" {
    if _, err := client.Instance.SetBackupSchedule(context.Background(), instance.ID, backupReq); err != nil {
        return diag.Errorf("error setting backup schedule: %v", err)  // ← 这里失败
    }
}
```

Vultr 侧 `status=active` 并不代表实例已经在备份子系统里注册完，这个窗口里
调 backup-schedule 会返回 404 `Invalid instance-id`。于是 Create 以错误结束
——但 `d.SetId()` 早已执行，Terraform 会把这条资源记进 state（标记为
tainted）。**"apply 失败"与"云上什么都没留下"不是一回事。**

注意那个 `context.Background()`：这次调用连 `d.Timeout(schema.TimeoutCreate)`
都不受约束，是 provider 里一处独立的可疑实现。

### 第 2 层：provider 的 Read 不认 404，于是孤儿 state 无法自愈

**现象**：refresh 阶段硬失败，`Planning failed`，**重跑结果完全相同**。

```
Error: error getting instance (0f41a228-...): {"error":"instance not found","status":404}
  with module.compute_console_nat_onwalk_net.vultr_instance.this
```

**根因**：Terraform 的正常语义是——refresh 发现资源在云上不存在，就把它从
state 里移除，下次 plan 计划重建。这依赖 provider 的 Read 正确识别"资源已
消失"。而 2.21.0 的实现是：

```go
instance, _, err := client.Instance.Get(ctx, d.Id())
if err != nil {
    if strings.Contains(err.Error(), "invalid instance ID") {
        d.SetId("")   // 认作 gone
        return nil
    }
    return diag.Errorf("error getting instance (%s): %v", d.Id(), err)  // ← 走到这里
}
```

Vultr 现在返回的措辞是 `instance not found`，**匹配不上那个字符串**，于是走
进 `diag.Errorf` 分支硬失败。

> **重要**：仓库在 [iac_modules efbcf28](https://github.com/ai-workspace-infra/iac_modules/commit/efbcf28)
> 已经把 provider 从 2.32.0 降到 2.21.0（为了避开第 3 次 run 的 panic）。
> 但**降级解决不了这个问题**——2.21.0 用的是上面那段字符串匹配，2.32.0 改成
> 了按 HTTP status 判断的 `checkIsMissing()`，反而更正确。选版本时要分清
> "崩溃"和"404 处理"是两件独立的事。

**后果**：一旦 state 里存在这样一个 ID，流水线进入**死循环**——每次运行都在
同一个地方失败，且失败本身不会改变造成失败的状态。人不介入就永远出不来。

### 第 3 层：destroy 打在空 workspace 上，报成功

**现象**：07:37 那次 destroy 输出 `Destroy complete! Resources: 0 destroyed.`
并以 0 退出，流水线全绿。而实例仍在 Vultr 上运行、计费。

**根因**：`terraform destroy` 只销毁 state 里有的东西。当时用户选的
`target_domains=all`，路由脚本把 `all` 映射到 `web-saas` 这一份资源声明，于
是 workspace 是 `...-web-saas`；而真实资源在
`...-web-saas-agent-proxy`。destroy 打在一个空 state 上，**这在 Terraform
看来完全成功**。

这与本仓库
[`2026-07-31-web-saas-tls-persistence-deadlock.md`](../../cases/runbook/2026-07-31-web-saas-tls-persistence-deadlock.md)
里第 2 层（健康检查只在切流量时跑）和更早的陷阱 #12（Ansible 匹配 0 台主机
仍 exit 0）是**同一类问题**：*一个作用于集合的操作，在集合为空时"成功"，但
调用者的本意是"这个集合非空"*。

## 修复

### 消除竞态（[iac_modules#232](https://github.com/ai-workspace-infra/iac_modules/pull/232)）

实例恒以 `backups = "disabled"` 创建 —— 创建期不再有 backup-schedule 调用，
第 1 层的竞态窗口消失。备份改由 apply 之后的幂等对账步骤落实，那时实例早已
active。`ignore_changes = [backups, backups_schedule]` 保证对账步骤把备份打
开后，下一次 plan 不会把它改回 disabled。

同一个 PR 里还修了一处渲染漂移：多份资源声明合并进一个 workspace 时
（`web-saas + agent-proxy`），合并后的 tfvars 只保留最后一份文件的
`name_prefix`，于是 web-saas 的主机被渲染成
`agent-proxy-uat-console-nat.onwalk.net`。label 是 resize preflight 按名反查
真实实例的锚点，它随 profile 组合漂移会让那条自愈路径失效。改为逐主机取自己
声明的前缀。

### state 对账（[platform-ops-toolkit#272](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/272)）

新增 `platform-ops_provision_reconcile-terraform-state.sh`，排在
plan/apply/destroy **之前**：state 里每个 vultr 资源按 ID 现查一次，404 的
从 state 移除，之后 refresh 只会看到真实存在的资源。

把"有人手工 `terraform state rm`"变成流水线自己每次开跑前的例行动作 ——
第 2 层的死循环被打断，**重跑重新成为有效手段**。

判据严格区分三种响应：

| HTTP | 含义 | 动作 |
|---|---|---|
| 200 | 资源还在 | 保留 |
| 404 | 资源确实没了 | `state rm`，记进 step summary |
| 401/403 | 凭据问题 | **硬失败，state 不变** |
| 其它 | 未知 | **硬失败，state 不变** |

误判一次的代价是把活着的机器从 state 里抹掉，下次 apply 会再建一台重复的
——所以除 200/404 之外一律拒绝猜测。

### destroy 作用域断言（同一 PR）

新增 `platform-ops_provision_assert-destroy-scope.sh`，排在 destroy 之前。
判据是**"云上还有没有本 profile 声明的实例"**，而不是"state 空不空"：

- state 里有实例 → 正常 destroy；
- state 空，云上按 label 也查不到 → 真的已经销毁干净，**放行**（重复 destroy
  必须保持幂等）；
- state 空，云上却有对应 label → **硬失败并报出实例 ID 与 IP**。

label 取自 render 阶段就落盘的 `hosts_manifest.json`，不依赖 apply 之后才存在
的 cmdb.json。

### 备份对账（同一 PR）

新增 `platform-ops_provision_reconcile-backup-schedules.sh`，排在 apply 之后，
按 `hosts_manifest.json` 幂等落实备份计划：先 GET 现状，一致就一个请求都不发。
只比较声明里出现过的字段——Vultr 对 daily 计划也会回填 `dow`/`dom`，拿它们跟
未声明的字段比会让每次运行都判成漂移、反复写同一份计划。

## 如何避免：可复用的判断原则

### 1. "操作失败"不等于"什么都没发生"——凡是会写状态的失败路径都要问一句"留下了什么"

第 1 层的本质：`apply` 红了，但云上多了两台机器、state 里多了两条记录。人的
直觉是"失败了就是没做"，而带副作用的 create 几乎总是相反的。

> **落地动作**：评审任何"创建资源 + 后置配置"的代码路径时，明确回答"后置配置
> 失败时，已创建的资源怎么办"。要么让后置配置不可能失败（挪出创建流程，本案
> 例的做法），要么在失败时显式回滚。让它半途失败并把残留留给下一次运行，是最
> 差的一种。

### 2. 有远端真实资源 + 本地状态记录的系统，必须有一条"对账"路径，且它要跑在业务动作之前

第 2 层的本质：状态与现实一旦不一致，系统没有任何自愈手段，只能等人。这不是
Vultr/Terraform 特有的——CMDB、Ansible inventory、任何缓存都一样。

判断标准很简单：**"这个失败，重跑一次会好吗？"** 如果答案是"不会，得有人手工
改状态"，那就缺一条对账路径。

> **落地动作**：对账要满足三个条件才安全——(a) 只做减法（移除陈旧记录），
> 增/改需要人确认；(b) 判据必须可判定，模糊的响应一律硬失败而不是猜；
> (c) 无漂移时零写操作，这样才能无条件、重复执行。

### 3. 不要用"作用于集合的操作成功了"来推断"集合非空"

第 3 层的本质，与 TLS 案例的第 2 层、陷阱 #12 完全同构：`destroy` 0 台成功、
健康检查 0 个端点成功、Ansible 匹配 0 台主机成功。**空集上的操作总是成功的。**

> **落地动作**：任何"对一批目标执行操作"的步骤，都要显式断言目标数量符合预期。
> 断言的判据要落在**外部事实**上（云上真的还有没有这台机器），而不是落在
> 内部记录上（state 里有没有）——因为内部记录出错正是要防的那件事。
> 同时注意别把幂等性一起断送掉：本案例里"已经销毁干净"必须继续放行。

### 4. 依赖第三方 provider/SDK 时，把"它如何判断资源已消失"当作要审的接口

第 2 层里有一个反直觉的点：**降级到"更稳定"的旧版本反而保留了更脆弱的 404
处理**。2.21.0 用字符串匹配上游的错误文案，上游改一次措辞就失效；2.32.0 改用
HTTP status 判断，这方面更正确。

> **落地动作**：选版本/升级时，除了看"有没有崩溃"，还要单独看"资源不存在时它
> 怎么表现"。这条路径平时不走，一走就是故障中，测不出来但代价最大。上游用错误
> 文案的字符串匹配来判断语义时，视作已知脆弱点，在自己这边加对账兜底。

### 5. 同一份声明在不同组合下必须渲染出相同结果

`name_prefix` 被后一份文件覆盖，导致同一台主机的 label 随 profile 组合漂移。
这类问题不会立刻炸，而是在依赖那个标识的地方（resize 按名反查）悄悄失效。

> **落地动作**：多份配置合并时，区分"确实属于整体的字段"（region）和"属于这
> 一份声明的字段"（name_prefix）。后者不能进合并后的全局命名空间，要在合并时
> 逐条粘到它所属的对象上。

## 如何独立验证（不必跑一次完整流水线）

```bash
# 1. 看某个 workspace 的 state 里到底有哪些实例 ID（只读 state，不触发 refresh）
terraform workspace select uat-vultr-vps-platform-ops-toolkit-web-saas-agent-proxy
terraform show -json | jq -r '
  def resources: .. | objects | select(has("resources")) | .resources[];
  [ (.values.root_module? // empty) | resources ]
  | map(select(.mode == "managed" and .type == "vultr_instance"))
  | .[] | "\(.address)\t\(.values.id)"'

# 2. 逐个 ID 现查是否还存在（404 = 孤儿；401/403 是凭据问题，不要当成 404）
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer ${VULTR_API_KEY}" \
  "https://api.vultr.com/v2/instances/<instance-id>"

# 3. 按 label 反查云上真实存在哪些实例（destroy 假绿的判据来源）
curl -sS -H "Authorization: Bearer ${VULTR_API_KEY}" \
  'https://api.vultr.com/v2/instances?per_page=500' \
  | jq -r '.instances[] | "\(.label)\t\(.id)\t\(.main_ip)"'

# 4. 确认某台实例的备份计划是否已按声明落实
curl -sS -H "Authorization: Bearer ${VULTR_API_KEY}" \
  "https://api.vultr.com/v2/instances/<instance-id>/backup-schedule" | jq .

# 5. 应急：手工剔除孤儿（对账步骤上线后，正常情况下不该再需要这一步）
terraform state pull > /tmp/state-backup.json   # 先留底
terraform state rm module.compute_<host>.vultr_instance.this
```

## 排查这类症状的入口

看到 provision 阶段 `Planning failed` 且**重跑结果完全一样**时，按这个顺序看：

1. 错误里有没有具体的资源地址和 ID？有 → 大概率是 state 与现实不一致，走上面
   的验证步骤 1、2。
2. 往前翻最近几次 run，找**最后一次成功的 destroy**，确认它的
   `Resources: N destroyed` 里 N 是不是 0。是 0 → 那次是假绿，真实资源可能
   在另一个 workspace。
3. 找最近一次失败的 apply，看它在报错**之前**有没有 `Creation complete`。有 →
   那些实例已经进了 state，是孤儿的来源。

## 相关 PR 索引

| 层 | 修复 | PR |
|---|---|---|
| 第 1 层：创建期竞态 | 实例恒以 `backups=disabled` 创建，备份移到 apply 之后 | [iac_modules#232](https://github.com/ai-workspace-infra/iac_modules/pull/232) |
| 渲染漂移 | label/tags 前缀逐主机取自己的声明；新增 `hosts_manifest.json` | [iac_modules#232](https://github.com/ai-workspace-infra/iac_modules/pull/232) |
| 第 2 层：孤儿 state 无法自愈 | plan 之前按 ID 现查并剔除 404 记录 | [platform-ops-toolkit#272](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/272) |
| 第 3 层：destroy 假绿 | destroy 之前按 label 断言作用域 | [platform-ops-toolkit#272](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/272) |
| 配套 | apply 之后幂等落实备份计划 | [platform-ops-toolkit#272](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/272) |
| 背景 | vultr provider 2.32.0 → 2.21.0（避开 panic，与 404 处理无关） | [iac_modules#231](https://github.com/ai-workspace-infra/iac_modules/pull/231) |

## 遗留

`target_domains=all` 在路由脚本里仍然只映射到 `web-saas` 一份资源声明——这是
07:37 那次 destroy 打空 workspace 的直接来源。改它要重排 workspace/state 布局，
风险远超本次修复范围；现在的作用域断言保证它**不会再假绿通过**，但语义本身
（选 `all` 却只处理一个域）尚未修正。

## 交叉引用

- [`2026-07-31-web-saas-tls-persistence-deadlock.md`](../../cases/runbook/2026-07-31-web-saas-tls-persistence-deadlock.md)
  ——第 3 层"空集上的操作总是成功"与该文第 2 层、陷阱 #12 是同一类问题的不同实例
- [`docs/resize-instance.md`](../../resize-instance.md)
  ——resize 的替换/认领流程，本案例的 state 对账与它的
  `adopt-resize-replacement` 共用同一套 state 操作模式（对账只做减法，认领需要
  人指定目标）
