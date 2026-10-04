# 独立 UAT / PROD 升级流水线

入口：`.github/workflows/environment-upgrade.yml`，仅 `workflow_dispatch`。
**所有实际演练只在 UAT；PROD 不允许 rehearsal、故障注入或应用回滚演练。**

## Selfhost web-saas 的兜底与备份职责

UAT 备份保存到 UAT selfhost web-saas 主机，PROD 备份保存到 PROD selfhost web-saas 主机。
不跨环境保存，不将 Actions artifact 或 runner 临时目录当作持久备份，不默认转存 S3。
Selfhost 是最后兜底运行路径和备份节点，不因此成为日常 schema 迁移目标。
常规升级必须保留兜底运行时、兜底数据库和旧应用能力，不重建/re-bootstrap 兜底主机。
备用路径切换和恢复真实业务数据库属于独立、人工审批的应急操作。

2026-10-04 核查发现：当前 UAT GitOps `topology/uat/hybrid/runtime-topology.yaml`
实际把 `accounts-selfhost-uat.onwalk.net` 设为 primary，把 Cloud Run 设为 fallback；
该路径与“selfhost 为最后兜底”的目标相反。实际演练启动前必须明确本次接受当前路径，
或另行评审并实施路由调整，随后重新验证数据库写入路径与回滚路径。不能仅依据本文
把 selfhost 当作已在运行中的 fallback。

主机由选定环境的 GitOps / CMDB 解析并核实实际身份，不接受用户任意输入主机/IP。
建议加密目录：`/data/backups/web-saas/<environment>/<release-tag>/<run-id>/`，权限 0700，
密钥来自对应环境 Vault，目录按运行唯一、不覆盖旧检查点；保留策略另行配置，禁止自动
删除本次升级的回滚点。备份前检查磁盘空间和兜底健康；校验复制后的 checksum、归属和
可读性，再在专用临时库验证恢复。不能将 dump 恢复到兜底主机正在服务的数据库。
兜底主机故障时备份也可能不可访问，这不是异地灾备；后续额外副本需要单独规划授权。

## 当前交付边界

已实现环境选择、候选制品来源校验、Environment 阶段、阶段执行契约、
非敏感证据清单、离线成功/失败演练及显式最终判定。

**尚未接入真实数据库/应用执行适配器。当前 live preflight 和 upgrade 会明确失败，
不会获取生产凭据、备份、迁移或部署。不能将本 PR 或演练成功视为 PROD 发布完成。**
`.github/scripts/environment-upgrade/adapters.json` 中两个环境目前均为空；这是启动前
阻断门禁，不是跳过后标记成功。现有 UAT 制品清单缺少完整业务验收和迁移 checksum
时，PROD 候选校验也会失败。
2026-10-04 查询到 `prod` Environment 尚无审核规则；候选校验会因此阻断 PROD。
现有受审环境名 `production` 不等同于本流水线使用的 `prod`，不能混用。
最新 UAT selfhost 构建的 CMDB 将 `web-saas-uat` 标记为 GCP Spot；对应 GitOps
资源声明未声明独立 `/data` 数据卷。尚未核验远端实际挂载与空间，不得假定
`/data/backups` 已是持久存储。`playbooks` role 会在 `/data` 不是独立挂载时
拒绝备份。容量、挂载及 CMDB 来源核验属于 IaC/GitOps 与主机执行前置条件，
不能用一个调用方传入的 `verified=true` 代替。

## 操作模式

| 模式 | 执行内容 | 是否可作为发布成功证据 |
| --- | --- | --- |
| rehearsal（仅 UAT） | 真实升级 → 验收 → 上一 digest 应用回滚（保留 schema）→ 同 digest 再晋级 → 再验收 | 是 UAT 演练证据，不是 PROD 部署 |
| preflight（默认） | 候选来源 + 环境审批 + 已注册只读数据库预检 | 否，仅预检 |
| upgrade | 预检 → 隔离恢复验证备份 → 增量迁移 → 同 digest 部署 → 业务验证 | 全部真实执行并通过后才是 |

输入：environment、mode、release_tag、candidate_run_id、expected_schema_version、
target_schema_version、migration_sha256。candidate_run_id 是 **Hybrid 子运行**，不是
Daily 父运行。UAT live 从受保护 main 执行；PROD 从对应的 annotated `v*` tag 执行。
PROD tag 必须对应 UAT 快照，运行必须已成功且携带完整业务验收，版本和 SQL checksum
必须匹配。所有环境都禁止使用浮动 latest 或在晋级时重新构建应用。

rehearsal 必须选 environment=uat，使用真实 UAT 候选制品、数据库和 UAT 专用审批/权限。
environment=prod + mode=rehearsal 在候选校验时直接拒绝，不获取数据库凭据。
故障注入应在 UAT 的专用测试库/测试资源执行，不能破坏 UAT 既有用户数据；当前入口
不接收任意故障注入参数。数据库恢复验证始终在目标环境对应的独立恢复库中，绝不
覆盖发布目标。PROD 恢复验证仅是隔离恢复库中的备份校验，不是故障或回滚演练。

## 阶段与证据

Environment 审批 → 数据库预检 → 可恢复备份 → 增量迁移 → 同 digest 晋级 → 发布后验证。
阶段间只有校验过的非敏感 receipt 可以流转；后续阶段检查同候选、同运行、同环境。
升级步骤放在同一受保护 job 中顺序运行，前一阶段失败时后续步骤不会执行。
最终 verdict 对请求的模式检查 job 成功，失败、取消、缺失或 skipped 都不算验收。

| 阶段 | 执行适配器必须实际证明的内容 |
| --- | --- |
| preflight | 精确起始版本/clean、非空用户和订阅样本、旧应用健康、权限/账本基线、完整旧 digest |
| backup | 同环境 selfhost web-saas、GitOps 主机身份核验、加密持久化、复制后校验、独立库恢复、恢复数据相符、兜底运行及数据库不受影响、起始版本、唯一检查点 |
| migration | 校验 SQL checksum、同备份绑定、数据库迁移锁、超时、有审核的 additive SQL、新旧应用兼容、数据保持、幂等、精确目标/clean |
| promotion | 实际运行 digest 相同、无需重建、不 bootstrap 共享服务、不复制 PROD→UAT 数据、保留原回滚 digest |
| verification | 原密码真实登录、权限/订阅/额度/财务及用量账本保持、无真实扣款退款、服务健康、digest 与 clean 目标版本 |

数据库备份保存在同环境 selfhost web-saas 的受限加密目录，不上传 Actions artifact。公开清单
只允许白名单字段；原始脚本输出、DSN、密码、邮箱、SQL dump 不发布。登录验收使用
专用账户，允许会话/登录时间/审计记录的必要写入，不修改真实用户权益和账本。

## 真实执行适配器接入（启用 live 前必须完成）

1. 在拥有执行职责的 domain CD / playbooks 中实现并审核 DB、备份、恢复、部署和
   业务探针；本仓库仅注册固定的单一薄委托入口，不接收 workflow 输入中的任意脚本/命令。
2. 委托入口固定为 `.github/scripts/environment-upgrade/delegate.sh`。`adapters.json`
   按环境声明经过审核的 `phases` 和该入口的 `path`、`sha256`；不得为每个环境、
   阶段复制一个脚本。委托入口按 `UPGRADE_PHASE` 调用 `playbooks` 的参数化 role。
3. 脚本读取 `UPGRADE_CANDIDATE_FILE`，从 `UPGRADE_EVIDENCE_DIR` 读取已验证前序证据，
   将原始 JSON 结果写入 `UPGRADE_RECEIPT_FILE`。只有 exit 0 且 receipt 全项验证通过
   才发布非敏感结果；boolean 字段是实际执行断言，不能填写人为批准或未执行的 true。
4. 在基础设施配置源声明并应用 OIDC → Vault 环境隔离角色与**精确 workflow allowlist**。
   未实施该步骤不授予流水线 id-token / 云写权限，不依赖 GitHub Secrets。
5. 配置 `uat`、`prod` GitHub Environment 的 ref 限制；PROD 必须要求审批、禁止自审。
   同名 Environment 不代表已配置保护，管理员应独立核实。
6. 锁对象必须对应实际数据库，跨入口迁移也须互斥；Actions concurrency 仅负责本入口。
   支持受控超时、中断后状态检查，不自动 force 清除 dirty。
7. 备份验证必须为每次运行创建专用恢复库并校验实际数据库身份不同；不能仅比较 DSN
   字符串。恢复工具不得操作源数据库，不调用现有会 DROP public 的恢复脚本。
8. 用 UAT 真实旧版本样本演练成功、事务失败、非事务失败、应用回滚和再次晋级，
   生成可审核证据后再启用 PROD。receipt 的结构测试不能证明远端事实。

当前 `playbooks` 已开始实现 `web_saas_release_upgrade` role，提供数据库只读预检
及同环境备份/隔离恢复的组成证据。完整业务验收、增量迁移及同 digest 发布还没有
对应的已审核执行 role，因此 adapter registry 仍为空，流水线继续阻断 live 执行。

## 回滚边界

不自动 down migration，不自动覆盖或切换生产数据库，不在升级失败后自动重新初始化。
迁移失败停止晋级；应用失败允许管理员发起独立的上一 digest 应用回滚，保留兼容 schema。
数据损坏先恢复到隔离实例并制定修复方案，生产覆盖恢复必须另行审批，保留新交易。
独立应用回滚入口尚未接入，本流水线不声称自动恢复生产可用性。
UAT rehearsal 中的 rollback 是演练阶段，由审核过的 UAT 专用适配器执行，不向 PROD 开放。

## 演练方式

离线契约测试：`python3 .github/scripts/tests/environment_upgrade_test.py`，不访问任何
数据库或云资源，不能替代 UAT 实际演练。
GitHub：接入真实适配器并合并主线后从 Actions 选择 Environment Upgrade，
mode=rehearsal、environment=uat，输入真实 UAT tag、Hybrid run、起止版本及 checksum。
升级、回滚、再晋级、再验收全部真实成功才报告 UAT 演练通过；缺少任何适配器时失败。

`environment-upgrade-ci.yml` 在相关 PR / 当前特性分支 push 自动执行同一离线测试。
失败注入包括：参数错配、非正式 PROD ref、缺少适配器、preflight 越权、空样本、
同库恢复、checksum/目标版本/备份/digest 不匹配、业务检查失败、跨环境重放、
前序证据缺失、敏感输出过滤、失败或 skipped 最终结果。
