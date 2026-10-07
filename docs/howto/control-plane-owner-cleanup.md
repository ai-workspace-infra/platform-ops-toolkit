# YAML/Shell 控制面清理审核状态

本批新增、改写的 Toolkit 控制模块统一采用 YAML + Shell/jq/yq。必要的 snapshots、release、GitOps reader 和数据操作 dispatch 保留；现存 Python CI guard/reader/dispatch 尚未全部转换，不能称整个仓库已经没有 Python。

## 已完成的代码与调用方

| 范围 | owner 与 caller | 当前证据 |
| --- | --- | --- |
| 5 个 PROD selfhost Python controller | Toolkit 参数化 `prod-selfhost-control` action；4 份配置转 YAML；旧控制器删除 | 21 项 Shell gate 测试；4 份真实历史 parent archive/receipt 的只读兼容校验 |
| k6、shared readiness、resize health、frontend/public/brand、XConnect 控制面探测 | 固定 SHA 的 Playbooks action | 已切正式 workflow；静态验证，不是新 UAT 验收 |
| XConnect node observation | Playbooks Role + same-run 动态 outputs/handoff 校验 | 9 项动态目标测试；仍为 summary-only，未证明安装、加入或桌面验收 |
| Vultr preflight、existing-target CMDB、SIT DNS、SMTP、Registry facts、Cloud Run/Cloudflare 部署 | 固定 SHA 的 IaC action；目标选择/OIDC 留在 Toolkit | 已切 caller；4 项资源事实、5 项 SMTP 与 4 项 Provider target binding 模拟校验；既有 DNS owner 测试通过 |
| UAT compute cleanup | GitOps 白名单 + 独立 main-only OIDC role + 固定 SHA IaC owner | 8 项模拟校验；策略 disabled，schedule 仅 plan；没有执行真实删除 |
| serverless 最终汇总 | Toolkit `serverless-summary` action | 17 项校验；本次选中阶段必须成功，并提供正确 owner SHA/environment/release/run/attempt 的 receipt；unknown、空值、缺件、跨 run 或未 accepted 均失败 |
| 扫描漏检 | 新 Shell active-entry guard 补充现有 guard | 8 项负例；不再按 `_test.sh` 文件名排除；识别 timeout 前缀和已退休 wrapper 的正式调用 |

审阅中的 owner pins：

- IaC Modules：bd098cba5acde525f2f1c4d3bc3a7bd6338c9077
- Playbooks：8b29bd81f03c7726f28698ea7c78471827d3c961
- GitOps cleanup declaration：7edb3b5b779aefea2ecab0ecf559357e390b6e4e

这些 SHA 属于待审核依赖；合并次序为 GitOps/owner 审核与合并，再审 Toolkit caller。若重新生成 owner commits，必须同步所有 action/workflow pin、summary pin 和精确 Vault workflow allowlist。

## 动态 Gateway/One 的验收契约

不要求人工填写固定 Gateway/One host、SSH user 或预先存在的 CMDB run。验收运行自己产生 IaC outputs，Playbooks 读取其中的地址、SSH user 和资源 ID；比较 `resource_ids.run`、variables.run_id、handoff.run、expiry 与 GITHUB_RUN_ID/ATTEMPT，并逐一比对 Gateway/One 的资源 ID、公私网地址和 transport endpoint。没有固定目标覆盖参数。

真实验收应记录当次 owner/caller SHA、GitOps SHA、IaC outputs/CMDB 的 provenance/checksum、服务/加入证据与实际清理回执。窗口结束或 SUMMARY_ONLY/UNVERIFIED 都不能称安装、加入或业务验收完成。

## 仍需迁移与删除核对

原冻结的 14 项仍存在。Caddy restore、existing-One/lab install/join/desktop/remote observation 归 Playbooks；SIT DNS/SMTP 已准备新 owner/caller，旧副本待验收；run/lease/prepare/DNS 混合职责链需要继续拆分到 IaC 与控制面，不能整包搬迁或直接删除。

补充扫描还发现 4 处现存执行，已经加入 YAML 冻结清单：`node-access-gcp` 的 OS Login/防火墙/云发现归 IaC；`setup-deployment-runner` 的 SSH/主机准备归 Playbooks；Stripe catalog/database bootstrap 与 overlay reset 归 Playbooks 或服务 owner。冻结仅防止扩大，不构成合规豁免。现有 Registry image build/publish 与其他未列入本批的 workflow 内执行也仍需按调用链继续审核。

静态搜索没有证明外部调用已退休；因此 unused Python helper、旧 Caddy restore 和两份 remote observation 候选未凭搜索结果删除。旧 executor 与过时测试必须在对应替代链路的实际证据确认后一起退休。

原 checkout 的 3 个未跟踪 cache 目录、9 个 `.pyc` 已清理；`all_scripts_eval.py` 和其他原 checkout 改动保留。

## Vault 与运行限制

本批只写源码，没有应用 live Vault role/policy。`scripts/vault/uat_cleanup_auth_contract.sh --check` 默认只读；审核后的 apply 与 check 应验证独立角色的精确 main workflow/ref 和两个只读路径。SIT/UAT/PROD/dev 现有角色新增的唯一固定 domain-owner workflow SHA 也需同步到 live Vault，再 dispatch。角色文件不是 live 授权证据。

Cleanup 的 enabled=false 策略不能 apply，也不删除数据库、持久数据或镜像；计划 receipt 的 accepted=false。未来启用要更新已审 GitOps policy SHA/caller，并审核真实 UAT 删除及不存在的回执。禁止仅修复旧 wrapper 路径就恢复原始删除器。

## 验证与未证明范围

82 项新增离线/模拟校验、15 项既有所有权 guard 测试、repository conventions、PROD bootstrap guard、owner DNS 模拟测试、Bash syntax、YAML 重复键与 composite metadata 检查通过。历史 resource/standby/initialized/billing parent 的只读兼容 replay 通过；这不等于本批新运行通过 UAT。

Actionlint v1.7.12 的完整检查仍包含既有诊断：未声明 workflow input/matrix output、空 choice option，以及过时的 App Token/job context 类型数据库。新增 metadata 解析问题已修复。`client-id` 与 `job.workflow_*` 的支持分别按 [官方 action metadata](https://raw.githubusercontent.com/actions/create-github-app-token/v3/action.yml) 与 [GitHub context reference](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)核对；不把这些类型数据库误报当作源码修复，也不声称完整 lint 为零。

按 [execution-ownership-migration](https://github.com/ai-workspace-lab/xworkspace-core-skills/blob/main/skills/engineering-standards/execution-ownership-migration/SKILL.md) 的要求：**“Delete the old copy last.”** 新运行/动态 UAT 证据尚缺，旧 executor 未删除，PR 保持草稿，不能合并或发布并声称全部迁移完成。
