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
必须另行从统一入口明确启动 legacy_import；这不是平滑 schema 升级。

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
