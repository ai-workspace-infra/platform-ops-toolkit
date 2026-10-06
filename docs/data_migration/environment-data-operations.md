# 环境数据操作：统一控制面与执行归属

唯一公共入口为 `environment-data-operations.yml`，选择 `environment=uat|prod` 与显式 `mode`。
替代 `data-migration.yaml`（也常被称作 migration.yaml）、`rollback-orchestrator.yml`、
`akamai-uat-migration-preflight.yml`、`environment-upgrade.yml`；不再另建 application-rollback 入口。

## 职责和调用

| 归属 | 本次职责 |
| --- | --- |
| Toolkit | 输入/环境审批、统一并发锁、同步 dispatch、运行关联、不可变候选/证据校验、最终失败传播 |
| Playbooks | 参数化数据库探针、显式导入、迁移、备份/隔离恢复、主机操作与其实现级测试 |
| GitOps | 环境拓扑、主机目标、主写入路径、持久卷和非敏感配置的声明源 |
| IaC Modules | Provider/资源/状态检查；本次 Akamai 只读预检实现和测试 |
| Accounts 等业务仓库 | 业务 SQL、迁移版本、应用源代码与镜像 |

Hybrid、Selfhost、Serverless 通过薄控制脚本 `dispatch.py` 派发同一入口，独立关联 ID
匹配子运行并等待最终 conclusion；子运行失败/取消/超时不会变成父流水线成功。
统一入口调用固定 **commit SHA** 的执行仓库 reusable workflow；执行仓库通过
`job.workflow_repository` / `job.workflow_sha` 检出自身，而不是误取 Toolkit 的代码。
见 [GitHub 官方 job context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)。
Actions 并发锁按环境统一；数据库实现仍须取得数据库迁移锁和执行超时，不能拿 Actions 锁替代。

## 操作范围与当前能力

| mode | 范围 / 前置门禁 |
| --- | --- |
| akamai_preflight | UAT-only，config_json.account 明确指定账号；IaC 只读查询，无 state rm/apply/destroy |
| legacy_import | UAT-only，config_json.confirm_legacy_import 必须为 JSON true；默认 dry_run；禁止 replace_public、站点全量恢复 |
| probe / selfhost_probe / selfhost_verify | 对应执行方的只读数据库/保留数据核验，不等价完整业务发布验收 |
| checkpoint | Playbooks 的受控检查点执行；元数据或补充 S3 备份不得冒充已满足 /data 隔离恢复的发布备份 |
| baseline / migrate | UAT-only，已审核 additive SQL、精确版本、checksum 和可信备份恢复证据；缺少证据停止 |
| selfhost_init | 仅显式 UAT 初始化；不用于普通 deploy/upgrade，已有数据库禁止隐式重建 |
| preflight / backup / upgrade / rehearsal | 保留完整发布控制契约；当前 adapters.json 尚未注册完整执行器，明确阻断，不宣称已完成真实演练 |
| rollback | 独立同 digest 应用回滚执行器尚未注册，明确阻断；旧 hard DB restore 已退役，不自动覆盖真实库 |

`config_json` 只接受非敏感配置，禁止 DSN、密码、私钥、任意命令/SQL；凭据由执行仓库 OIDC→Vault 取得。
普通发布永远不自动复制 PROD→UAT。旧 migrate/deploy+migrate 的自动导入路径被阻断，管理员
必须明确启动 legacy_import；这不是平滑 schema 升级。

### Daily 的显式一次性导入

`daily-main-snapshot.yaml` 的 `enable_migration=true` 不传给 Hybrid，而是先派发
本统一入口的 `mode=legacy_import`，绑定本次不可变 tag 为 `release_tag` 和
`accounts_ref`，使用唯一关联 ID 等待最终成功；失败、取消、超时均停止，不能进入 Hybrid。
`enable_migration=false`（默认）不派发任何导入。导入与 schema migration／baseline adoption
互斥，只能目标 UAT；不会新增 PROD 导入或重新 bootstrap 共享服务。

`migration_config_json` 仅传非敏感配置。显式 enable 开关会补充
`confirm_legacy_import=true`；默认 `dry_run=true`、`accounts_transport=direct`。
预览成功也不部署应用，不能冒充实际迁移或升级验收。审核写入请求须显式
`dry_run=false`，并提供执行 owner 所需的来源、目标、身份及备份条件；不推断 IP、
数据库或替换策略。配置中的 DSN、密码、SQL 和命令会在派发前拒绝。

直接连接的凭据沿用 Vault `kv/uat/accounts-migration`：
`MIGRATION_SOURCE_DSN`、`MIGRATION_TARGET_DSN`；SSH 源访问使用
`MIGRATION_SOURCE_SSH_PRIVATE_KEY_B64`，仅执行 owner 在运行时读取。
源凭据不符合只读身份／环境守卫时停止，不为完成导入而降级安全门禁。

### 数据子任务闭环

导入完成不能仅凭 dispatch 或 workflow conclusion 放行。Playbooks 发布精确
run/attempt、correlation、owner SHA、Accounts ref/实际 SHA、UAT 主机和 CMDB
caller 的脱敏回执；Toolkit 从该精确 child 下载并核验，不按最近一次运行猜测。
direct 导入的 preview 只接受 `target_preview/not_attempted`；显式实写必须到达
`target_verify/verified` 且 `convergence_verified=true`，同快照只读重放已收敛。
缺回执、错误来源/目标、旧 attempt 或仅 apply 成功但验证缺失均停止后续发布。

`unverified` 表示实写或验证阶段尚未证明目标状态，失败、超时和取消不等于回滚。
恢复前核实现状，不自动重复写入。旧版 token 主键 `sessions` 由 Accounts 导入器
按实际 schema 兼容，不由导入脚本隐式重建表或替换 public schema；旧 immutable tag
不移动。修复版导入器与原发布 tag 分别记录，新的 Daily 发布使用包含修复的新快照。

注意：当前 `legacy_import` 是用户／身份域的合并，不是完整业务库复制；其成功不证明
订阅、账本、schema 基线或 UAT Selfhost 两跳初始化已完成。完整 DB 基线需要单独的
已审核执行契约和证据，不能由 Daily 的派发开关暗中实现。

例：只读 UAT Akamai 预检：

```sh
gh workflow run environment-data-operations.yml -R ai-workspace-infra/platform-ops-toolkit \
  --ref main -f environment=uat -f mode=akamai_preflight \
  -f config_json='{"account":"manbuzhe2026"}'
```

一次性导入（先 dry run，仍会读取生产身份数据，需授权）：

```sh
gh workflow run environment-data-operations.yml -R ai-workspace-infra/platform-ops-toolkit \
  --ref main -f environment=uat -f mode=legacy_import \
  -f config_json='{"confirm_legacy_import":true,"dry_run":true,"accounts_transport":"ssh","accounts_source_backend":"supabase","accounts_target_backend":"vps"}'
```

主机目标以审核的环境 GitOps/CMDB 为准，不接受任意目标替代身份核验。
Selfhost 基线／验收当前限定每环境一个 `web-saas-<environment>` 主机；多主机请求停止，
避免 matrix 共享输出把不同主机的基线回执覆盖或串用。扩展多主机需显式的逐主机回执映射。

## Vault 迁移顺序

1. 先合并执行仓库，再固定其 merge SHA；不以浮动 main 为执行版本。
2. 将该 SHA 的 called workflow 加入对应角色的 job_workflow_ref。repository/ref 仍约束
   **调用方 Toolkit**；不可把 repository 改成 Playbooks 来扩大错误的权限。
3. UAT 才允许导入与 Akamai；PROD 保留 tag/release ref 限制，无导入白名单。
4. 先添加新 claims，再合并统一入口/调用方并删旧文件，最后移除旧 claims；现场读回核验。
5. PROD 必须存在 reviewers 且 prevent_self_review=true。环境保护缺失时，统一入口直接阻断。

## 非破坏性升级与验收

审批 → 预检 → 同环境 `/data/backups/web-saas/<env>/<tag>/<run-id>/` 加密检查点（0700）
→ 独立临时库恢复验证 → 已审核增量迁移 → 同 digest 晋级 → 原密码/权限/订阅/额度/账本验收。
不上传 SQL dump、密码哈希、邮箱、DSN 或私有探针内容到公开 Actions；只发布脱敏回执。
不重复 PROD→UAT 同步，不重建表，不 bootstrap Vault/Observability。
应用回滚保留扩展 schema；DB 失败向前修复，脏状态不得 force 清零。覆盖 PROD/切库另行审批。

完整能力未注册、缺少备份恢复证据、版本/checksum/digest 不一致、dirty 或业务验收失败均停止晋级。
测试通过、PR 合并、dispatch 成功都不是运行时验收。完整发布证据仍遵循
[升级验收契约](environment-upgrade.md)；旧文档中的旧入口/硬恢复示例不再适用。
# 参数化 Selfhost 组件角色

`mode=preflight|backup` 可以显式选择 `config_json.execution_path=selfhost_roles`。
控制面只派发固定 SHA 的 Playbooks `selfhost-data-lifecycle.yml`；角色、动态
CMDB inventory、主机操作、加密备份与隔离恢复归属 Playbooks。该组件路径目前
UAT-only，不支持 schema 初始化、复制数据、迁移、应用发布或 PROD 晋级。
backup 需要显式 opt-in、来源／baseline／授权非空订阅样本，密钥只在 Vault
运行时解析。组件成功不是 G1/G2/G3 或完整发布验收。

参见 [状态机角色映射与执行边界](https://github.com/ai-workspace-infra/playbooks/blob/main/docs/data-operations/uat-state-machine-role-map.zh.md)。Accounts 的受控 Selfhost migrator
尚未实现，migration 角色明确阻断；完整升级／演练适配器不因此自动注册。

`.github/scripts` 清理使用 `scripts/ci/script_ownership_verify.py` 门禁：新增执行
脚本或修改冻结的旧执行脚本均失败，只允许按职责移出。当前仍有 27 个旧执行
候选项，登记在 `scripts/ci/legacy-execution-inventory.json`，不能声称已全部迁移。
