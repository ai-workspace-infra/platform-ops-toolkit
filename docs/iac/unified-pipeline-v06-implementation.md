# 多云 IaC pipeline v0.6 实施与验证

设计文档已由 knowledge PR #130 合并。本变更实现契约、owner actions、统一编排及 caller 接入；尚未进行真实 Vault/cloud/state UAT，未删除 legacy 执行副本。

## 入口

`iac-pipeline-multi-cloud-master.yaml` 同时支持 dispatch/call，固定八个 job：prepare、bootstrap、account、resources、destroy-resources、destroy-account、destroy-bootstrap、summary。正向 bootstrap → account → resources；销毁 resources → account → bootstrap。所选阶段失败或取消必须阻断，未选路径记录 not_selected。

`iac-pipeline-multi-cloud-stages.yaml` 只有 bootstrap/account/resources 三个可复用 job，没有内部固定 needs。master 为六个执行位置选 stage/action，传递固定 GitOps/IaC SHA、契约摘要和前置证据。各阶段 runner 和保护环境归 Toolkit；IaC-specific actions 均从同一固定版本 IaC checkout 本地调用。namespace 身份摘要和 Terraform backend lock 同时防止并发 state 写入。

`iac-self-check-matrix.yml` 四个 job：prepare/self-check/execute-iac/summary。它是 IaC PR/push 静态事件的唯一入口，覆盖 `main`、`release/**`、`terraform-hcl-standard/**` 和所有 `iac-*` workflow 变更；check 仅静态报告六云覆盖，不登录 Vault。显式 plan/apply/destroy 调用 master，master 不调用矩阵入口。终端 summary 核验当前运行报告/receipt，不以 skipped 掩盖失败。

运行需要 `environment` 与 GitOps `target_manifest`。`stage_scope` 默认为 resources；完整三层须显式 all；bootstrap_mode 默认 verify，reconcile 必须显式 bootstrap/all。可传 GitOps/IaC revision，但入口只解析一次并固定完整 SHA，随后所有认证、模块与证据使用这两个 SHA。

旧 baseline/account/resources 名称仅作兼容 wrapper，只保留 `workflow_dispatch`/`workflow_call`；它们不再各自监听 PR/push 或重复调用静态门禁。GCP/UCloud/Akamai 独立资源入口转发矩阵；AWS/GCP OIDC 原名保留身份恢复授权。旧参数只校验身份或映射目标，不能覆盖 GitOps；组件选择、隐式 adoption、state migration、跨云默认账号不再授权部署。

## 第一批基础清理与保留项

统一 owner/caller 切换后，Toolkit 内无当前 caller、恢复职责或 UAT gate 的 `terraform-command`、`setup-iac-env`、旧 `platform-ops_iac-self-check.py` 和 `cmdb-ssh-login.sh` 已删除。静态自检由固定 IaC owner ref 的 `.github/actions/iac-self-check` 提供；阶段执行继续由固定 IaC actions 承担，没有把 Terraform 或 SSH 实现留在 Toolkit。

Toolkit 的 `scripts/cloud/bootstrap/aws/reconcile_github_oidc_trust.sh` 与 `adopt_github_oidc_terraform_state.sh` 暂时保留并标记为待退休。固定 IaC owner SHA `be8456282f7495e098170e0894e742605a94dae6` 已分别通过 `iac-aws-cloud-bootstrap` 与 `iac-maintenance` action 提供替代调用，但替代脚本不是字节等价副本：owner reconcile 增加临时 session credential 限制，owner adoption 去掉三个 Terraform target 限制。删除前仍需逐项确认行为等价或明确接受差异，完成精确 caller 收敛，并记录相同 environment/account/state 的 UAT receipt 与收敛结果；布局测试和静态引用本身不构成退休证据。

## Caller 与保护

Selfhost 分为 resolve-targets → master resources → provision receipt/inventory verification → 既有 Playbooks。保留 existing-host/native/data 操作；非手动事件不启动资源/应用变更。新 owner inventory 脱敏后恢复既有 flat CMDB、inventory.ini 与部署矩阵，应用凭据准备继续使用原 Vault 授权。GitOps 没有唯一审核目标时明确阻断。

Serverless 从 topology.spec.iac.target_manifest 解析实际目标，资源 receipt 验证成功后才放行应用部署。cloud_provider 新增 ucloud，但仍表示关联云，不能据此迁移运行时。现有声明只核验共享 GCP network/Artifact Registry，Cloud Run、Cloudflare DNS/application owner 保持原边界，schema/data-only 不自动执行 IaC。

销毁只允许声明授权、单目标独占且无外部引用的 state；共享身份/网络/backend/持久卷不能随资源流水线删除。当前 GitOps Akamai 目标只保留既有 state，destroy 暂不启用。GCP identity state 保留旧 key，不与 workload/account 混管。

Vault 角色源码增加准确的 reusable stages job_workflow_ref，只沿用该角色已有 main/release/tag ref 范围，其他 claim 和 policy 保持不变。上线前需要受控应用这些角色源码，Git 提交并不证明 live Vault 已生效。

## 能力及发布门槛

六云使用统一契约和独立认证；Azure renderer、未拆分的独立 account state，以及缺真实 GitOps target/auth/state 的资源，明确 unsupported/blocked。不存在 registry 即可 deploy 的默认目标。静态成功、验证已有共享资源、实际 Terraform apply 和应用验收是不同证据。

Owner 与 GitOps PR 应先合并，再合并固定引用它们的 Toolkit PR。保持不可变 owner/caller SHA，在 UAT 验证具体 environment/account/workspace 的 plan、云身份、state 无改名、失败传播、cleanup、inventory 与应用消费。PROD 继续经过已有受保护环境及不可变发布边界。未完成这些证据前，不删除 legacy 源码或宣称六云 runtime 验收完成。

离线验证包含 owner 故障契约和 actions 依赖/脚本解析、Toolkit DAG/caller 回归、actionlint、工作流门禁/引用/仓库归属扫描，以及六个现有 Akamai manifest 的私有目录渲染/fmt。未执行 Terraform init/plan/apply/destroy 或云/Vault 写入。
