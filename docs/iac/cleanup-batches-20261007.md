# IaC owner 清理批次与交接记录

依据设计 v0.6，保持 master 八 jobs、正反独立 DAG、stages 三 jobs。Toolkit 持有全部交付入口/审批/运行关联/放行；IaC 提供声明绑定的云资源 actions；Playbooks 提供主机/服务 actions 与 Roles。

## 批次与证据

| 批次 | 改动 | 源码验证 | 运行证据/退休状态 |
| --- | --- | --- | --- |
| 1 无调用与静态入口 | 删除旧 Terraform command/setup env/self-check/SSH helper；静态触发集中矩阵 | 契约、gating、scanner 及反例 | 无运行路径变更；AWS 恢复旧脚本仍待差异审查及运行证据 |
| 2 兼容 wrapper | 保留 AWS/GCP OIDC、GCP/UCloud/Akamai 与三个 stage dispatch/call | 原 wrapper 路由契约 | GCP 尚有 caller/PROD evidence consumer；不得仅减少文件数而删除 |
| 3 GCP/主机 owner | GCP auth/node access；deployment runner、Vault stage owner | 各组 owner/caller tests | 按固定 owner SHA 交接；旧副本留至对应 UAT/rehearsal 与回退窗口关闭 |
| 4 IaC delivery workflow | 新 Toolkit `iac-cloudflare-serverless-domains.yaml` / `iac-akamai-state-preflight.yaml` 调 IaC actions | exact SHA/caller/environment/篡改声明负例；声明检查先于 Vault | Vault claim 源码已补；未应用 live Vault。旧 IaC workflow 暂留 LEGACY |
| 5 XConnect 混合链 | 按云/state、主机/服务、调度分别处理 | 子链独立验证 | 不将 run.sh 整包原样移入一个 owner |

## 第四批的契约

- Serverless domains 的 parent controller 保持 `serverless-orchestrator.yml`，runtime topology 来自精确 GitOps SHA；独立新 Toolkit job 保留 public-dns concurrency 和 Environment 审批。资源执行复用已有 IaC domain action，receipt 的 owner SHA 与其固定 checkout 一致。Cloudflare GTM aliases 仍由原受控 owner 管理。
- Akamai preflight 的 parent controller 保持 `environment-data-operations.yml`，仅 UAT。操作入口解析所选 GitOps ref 后绑定完整 SHA，IaC action 仅调用原只读 state/inventory 查询，报告增加 owner/GitOps/run/attempt 绑定。报告缺失必须失败，不能把 artifact upload 当成查询成功。
- Vault 新 `job_workflow_ref` 精确到 Toolkit workflow 路径及 `refs/heads/main`，保留旧 claim 以支持回退窗口。源码修改不证明 live Vault 已更新；新 wrapper 在策略应用前会失败，不能扩大 wildcard 来掩盖。
- 保留 `.github/workflows/akamai-state-preflight.yml` 与 `cloudflare-serverless-domains.yml` 的旧版本供固定 SHA 回退。新 Toolkit caller 不再引用它们；完成对应身份/运行/receipt 验证后才能退休。

## 运行验收边界

本轮源码测试和 mock rehearsal 不证明真实云、state、主机、Raft 或业务状态。任何失败/取消后先确认目标状态，不假定自动回滚。不得为了验证归属重构执行真实 apply/destroy、DNS cutover、Raft remove-peer、数据迁移或 Vault 策略写入。

未证明真实验收的执行旧副本保留；静态 CI 可以留在 IaC 仓库。Provider registry 能力与 Toolkit allowlist/GitOps 环境默认须分别治理，不能机械搬迁整个 config 目录。
