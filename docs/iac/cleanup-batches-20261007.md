# IaC owner 清理批次与交接记录

依据设计 v0.6，保持 master 八 jobs、正反独立 DAG、stages 三 jobs。Toolkit 持有全部交付入口/审批/运行关联/放行；IaC 提供声明绑定的云资源 actions；Playbooks 提供主机/服务 actions 与 Roles。

## 批次与证据

| 批次 | 改动 | 源码验证 | 运行证据/退休状态 |
| --- | --- | --- | --- |
| 1 无调用与静态入口 | 删除旧 Terraform command/setup env/self-check/SSH helper；静态触发集中矩阵 | 契约、gating、scanner 及反例 | 无运行路径变更；AWS 恢复旧脚本仍待差异审查及运行证据 |
| 2 兼容 wrapper | 保留 AWS/GCP OIDC、GCP/UCloud/Akamai 与三个 stage dispatch/call | 原 wrapper 路由契约 | GCP 尚有 caller/PROD evidence consumer；不得仅减少文件数而删除 |
| 3 GCP/主机 owner | GCP auth/node access 与 GitOps reader；Cloud Run/OCI facts；deployment runner、Vault stage/自动迁移探测/controller setup owner | owner/caller tests；无 Docker 的只读 registry query；空 traffic 不能放行 | 固定 owner SHA 交接；旧副本留至对应 UAT/rehearsal 与回退窗口关闭 |
| 4 IaC delivery workflow | 新 Toolkit `iac-cloudflare-serverless-domains.yaml` / `iac-akamai-state-preflight.yaml` 调 IaC actions | exact SHA/caller/environment/篡改声明负例；声明检查先于 Vault | Vault claim 源码已补；未应用 live Vault。旧 IaC workflow 暂留 LEGACY |
| 5 XConnect 混合链 | Lab Terraform/state/lease 切 IaC；Accounts invitation 切 Playbooks；Vault 授权和 private handoff 留 Toolkit | exact-run state、未知资源/缺标签拒绝销毁；HTTP/邀请隐私测试 | host/service chain 分组迁移；run.sh 旧副本冻结，H1–H6 合同记录尚未验收的子链 |
| 6 non-IaC / TLS | runtime inventory/key adapter 与 Caddy certificate restore 归 Playbooks；Toolkit 调固定 owner | 显式域名记录缺项拒绝回退；私密 vars 无条件清理；既有 Role 复用 | caller 已随 #1375 合并；旧 renderer/restore 保留待真实验收 |
| 7 XConnect 主机/数据面 owner | 精确 target、预审 known_hosts 的 Role runner；同 run/attempt 的 Gateway/One、TLS、精确 peer handshake、private ping/HTTP receipt | 多 runtime 配置拒绝执行；精确 peer/目标/owner SHA 及私网地址反例 | additive owner 已合并；缺可信 host-key 与 private probe 声明，默认 host caller 未切换；H6 existing-One 尚未拆完 |
| 8 扫描治理 | 扫描 node_deploy Python/Shell/import/source；Accounts 服务写不再豁免 | 20 scanner tests、13 active-entry mock checks | 21 项冻结债务保留；不表示已完成迁移 |

## 第四批的契约

- Serverless domains 的 parent controller 保持 `serverless-orchestrator.yml`，runtime topology 来自精确 GitOps SHA；独立新 Toolkit job 保留 public-dns concurrency 和 Environment 审批。资源执行复用已有 IaC domain action，receipt 的 owner SHA 与其固定 checkout 一致。Cloudflare GTM aliases 仍由原受控 owner 管理。
- Akamai preflight 的 parent controller 保持 `environment-data-operations.yml`，仅 UAT。操作入口解析所选 GitOps ref 后绑定完整 SHA，IaC action 仅调用原只读 state/inventory 查询，报告增加 owner/GitOps/run/attempt 绑定。报告缺失必须失败，不能把 artifact upload 当成查询成功。
- Vault 新 `job_workflow_ref` 精确到 Toolkit workflow 路径，ref 范围逐项继承该环境现有的 `bound_claims.ref`；PROD 仅 version tag/release branch。Akamai UAT preflight 保持 main。保留旧 claim 以支持回退窗口。源码修改不证明 live Vault 已更新；新 wrapper 在策略应用前会失败，不能使用不受限制的 `@*` 掩盖。
- 同仓 `./.github/workflows/...` 调用与 caller 使用同一提交，OIDC 的 `job_workflow_ref` 描述被调用 workflow，因此只补 main 会阻断 tag caller。依据 [GitHub reusable workflow 文档](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)与 [OIDC claim 文档](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-with-reusable-workflows)，新增测试同时验证 PROD tag 可匹配、main/feature ref 不可匹配。
- 保留 `.github/workflows/akamai-state-preflight.yml` 与 `cloudflare-serverless-domains.yml` 的旧版本供固定 SHA 回退。新 Toolkit caller 不再引用它们；完成对应身份/运行/receipt 验证后才能退休。

## 运行验收边界

本轮源码测试和 mock rehearsal 不证明真实云、state、主机、Raft 或业务状态。任何失败/取消后先确认目标状态，不假定自动回滚。不得为了验证归属重构执行真实 apply/destroy、DNS cutover、Raft remove-peer、数据迁移或 Vault 策略写入。

未证明真实验收的执行旧副本保留；静态 CI 可以留在 IaC 仓库。Provider registry 能力与 Toolkit allowlist/GitOps 环境默认须分别治理，不能机械搬迁整个 config 目录。

## 已发布提交与 PR

| 仓库 | PR | 结果 | 内容 |
| --- | --- | --- | --- |
| Toolkit | [#1374](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1374) | main 已合并 | 无 caller 的旧 actions/scripts 清理与统一静态触发 |
| IaC | [#415](https://github.com/ai-workspace-infra/iac_modules/pull/415) | main 已合并 | GCP auth/access 与两个 delivery adapters；Pages detach 失败必须传播 |
| Playbooks | [#620](https://github.com/ai-workspace-infra/playbooks/pull/620) | main 已合并 | deployment runner、Vault stage 与 existing-node contract |
| IaC | [#416](https://github.com/ai-workspace-infra/iac_modules/pull/416) | main 已合并 | cloud target/facts readers、XConnect IaC lifecycle |
| Playbooks | [#621](https://github.com/ai-workspace-infra/playbooks/pull/621) | main 已合并 | Vault migration observation、node-stage runner、Accounts bootstrap |
| Playbooks | [#622](https://github.com/ai-workspace-infra/playbooks/pull/622) | main 已合并 | non-IaC inventory、Caddy restore、XConnect trusted-target runtime 与数据面证据 |
| Toolkit | [#1375](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1375) | 按用户要求合并 main；身份策略与运行验收仍待验证 | 精确 SHA caller、阶段放行、receipt 与审批；不把静态 CI 称为迁移验收 |
| IaC | [#417](https://github.com/ai-workspace-infra/iac_modules/pull/417) | CI 通过并合并 main | lifecycle 原始退出码、敏感日志、lease 和 state-read 失败保护 |
| Playbooks | [#623](https://github.com/ai-workspace-infra/playbooks/pull/623) | CI 通过并合并 main | XHTTP verifier、同 run 私网 probe 及失败关闭 cleanup |
| Toolkit | [#1376](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1376) | CI 通过并合并 main | 固定发布 owner caller、12 个控制面测试/fixture 迁移、精确 Vault claims |

本批次 IaC caller 固定 `d7e49189a5de9c105a940f1c79abfb3b2b33bbd4`，XConnect/runtime/observation 与 serverless frontend probe caller 固定 Playbooks `9d585e147348800b1603c4f7b0d8a6bcf0546007`；其他未改动 owner caller 保持其审核版本。

后续 48 文件逐项映射与 [main 只读 rehearsal](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37641969087) 见 [交接记录](../howto/owner-followup-20261007.zh.md)。该 run 通过 Vault 登录、固定 checkout、匿名 Accounts/Portal 边界和 Terraform backend=false preflight；未执行 SSH、云变更或 Accounts 写入。新 known_hosts 字段及 runtime-control live Vault role 仍未证明，不据此删除完整 host/service 旧链。
