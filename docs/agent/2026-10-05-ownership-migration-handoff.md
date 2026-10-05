# 执行职责迁移交接快照（2026-10-05）

本文是当前迁移工作的可执行交接入口。历史批次、旧 SHA 和失败记录继续保留在 [2026-10-04 执行职责迁移交接](2026-10-04-execution-ownership-migration-handoff.md)；本文只记录当前主线状态、已验证证据和下一步门禁。

## 1. 总体边界

| 边界 | 归属 | 允许内容 | 不允许内容 |
| --- | --- | --- | --- |
| 控制面与验收 | `platform-ops-toolkit` | workflow 入口、环境/版本选择、审批、Vault OIDC、GitOps reader/validator、调用顺序、发布证据和验收门禁 | 通用 Provider、主机、数据库、Observability 执行实现 |
| 声明式目标状态 | `gitops` | 非敏感 desired state、release 引用 | CMDB、执行脚本、运行时私密状态 |
| 云资源与 Provider | `iac_modules` | 云资源、Provider、Cloudflare DNS、状态/租约操作、CMDB 事实 | 主机服务部署、应用配置 |
| 主机与服务 | `playbooks` | 主机配置、服务部署、迁移、备份、恢复、服务健康和 Observability Role | 云资源创建、DNS Provider 操作、第二份环境拓扑 |

所有批次固定顺序：

**新增通用 Role/Workflow → 切换 Toolkit caller → 验证 → 删除旧副本**。

删除旧副本前必须同时具备 owner 合并 SHA、caller 合并 SHA、实际 UAT 运行证据、失败/幂等/敏感清理验证和删除后的完整 CI 证据。

## 2. 当前主线和统计

| 项目 | 当前值 | 证据/说明 |
| --- | --- | --- |
| Toolkit `origin/main` | `13b24acc9d9e2d638b398ab857c0598375d3e58f` | 已合入 XConnect caller #1283、fail-closed upgrade delegate #1284 和本交接快照 #1286 |
| Playbooks `origin/main` | `94b9ca010efb1eeb62469f791a910dd361f1abae` | 已合入 XConnect runtime owner #574 |
| `.github/scripts` tracked 文件 | **190** | `git ls-tree -r --name-only origin/main .github/scripts | wc -l` |
| `find .github/scripts | wc -l` | **210** | 包含目录项，不等于文件数 |
| scanner 冻结 legacy execution | **15** | #1279 扩大检测覆盖，不表示本批新增 15 个脚本 |
| PROD | **未触碰** | 未执行 PROD 部署、迁移、升级、回滚或数据恢复 |

当前冻结登记以 `scripts/ci/legacy-execution-inventory.json` 为准。主要遗留项包括：

- Playbooks 方向：`xconnect-existing-one-uat/deploy.sh`、`xconnect-lab/deploy.sh`、`desktop.sh`、`enroll-node.sh`、`gateway.sh`、两份 remote observation 脚本、Caddy restore。
- IaC Modules 方向：`xconnect-lab/run.sh`、`lease.sh`、`prepare.py`、`reconcile-gateway-dns.sh`、UAT/SIT DNS reconcile、SMTP Secret Manager 写入。

scanner 的 `owner` 只是评审提示，不代表迁移完成；目录数量也不能作为完成标准。

## 3. 本批已完成：XConnect 第一子批次

### 3.1 Playbooks owner

- PR：[playbooks#574](https://github.com/ai-workspace-infra/playbooks/pull/574)
- merge SHA：`94b9ca010efb1eeb62469f791a910dd361f1abae`
- 新增 Role：`roles/vhosts/xconnect_lab_runtime`
- 新增入口：`xconnect-lab-runtime.yml`
- 支持操作：`gateway_identity`、`gateway`、`one`、`gateway_verify`、`one_verify`

Role 只执行主机/服务操作，复用既有 `vhosts/xconnect_gateway` 和 `vhosts/xconnect_one`，不复制 Gateway/One 的第二套实现。Terraform、云资源、DNS、Cloudflare、GitOps 写入和 PROD 均不在 Role 中。

验证操作使用固定的 `systemctl`、`xconnect-gateway status`、`xconnect status`，隐藏可能携带 credential 的输出；入口要求显式 target，默认只允许 UAT。

Owner 证据：

- gitleaks：通过；
- Playbooks guards：通过；
- Ansible syntax：通过；
- disposable PostgreSQL 加密备份/隔离恢复 CI：通过；
- 定向本地测试：29 项通过；本机无 CI PostgreSQL service 时，容器集成测试跳过。

### 3.2 Toolkit caller

- PR：[platform-ops-toolkit#1283](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1283)
- merge SHA：`8fd8693ad47d3262274367e8c0a28e44968d6732`
- 新增入口：`.github/workflows/xconnect-runtime-control.yml`
- 固定 owner ref：`94b9ca010efb1eeb62469f791a910dd361f1abae`
- 当前暴露操作：只读 `gateway_verify`、`one_verify`

Toolkit 负责环境固定、输入校验、UAT environment protection、Vault OIDC 临时 SSH 身份、精确 target 选择和调用顺序；主机执行留在 Playbooks。

Caller CI 证据：gitleaks、跨仓库 ownership contract、workflow gating 全部通过。

## 4. 当前尚未完成的部分

### 4.1 UAT 尚未执行

本批没有执行新 caller 的 UAT dispatch，因为没有可审计的精确 CMDB `target_host`、`target_user` 和 `state_dir`。不得从 DNS、GitOps IP、旧脚本 wildcard discovery 或猜测的 SSH 用户补齐参数。

下一步应使用已合并 Toolkit main 的 `xconnect-runtime-control.yml`，只选择 `gateway_verify` 或 `one_verify`，并记录：

`Toolkit SHA + Playbooks SHA + environment + target + target user + state_dir + run ID + sanitized status receipt + 是否修改主机`

### 4.2 安装/加入 caller 仍未切换

下列旧逻辑仍未完成完整迁移：

- Gateway binary/CA/identity/enrollment/up/systemd；
- One binary/CA/invite/join/sync/systemd；
- Accounts invite 创建与主机加入结果的分离；
- existing-One 的固定目标、runtime artifact 和健康验证；
- desktop observation、node observation 和 lease expiry 的职责拆分。

下一子批应先在 Playbooks 补齐参数化 Role/Workflow，输入限定为固定 environment、CMDB target、immutable binary、短期 invite、CA、device/network/gateway identity 和 run ID；再切 Toolkit caller。不得把 invite/API 成功标为主机已加入。

### 4.3 旧副本尚未删除

owner/caller 合并不等于 cleanup。旧 `xconnect-lab` 与 existing-One 脚本必须保留到安装/加入 caller 的 UAT 成功、失败路径和幂等重跑全部验证后，再按文件粒度提交独立删除 PR。

### 4.4 IaC 子批次尚未完成

`run.sh`、`lease.sh`、`prepare.py` 的 Terraform/provider/state 逻辑和 `reconcile-gateway-dns.sh` 的 DNS Provider 操作，应分别迁移至 IaC Modules；不能放入本批 Playbooks Role，也不能把 GitOps 变成 CMDB。

### 4.5 Caddy fail-closed caller 状态

- Toolkit PR [#1284](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1284) 已合并，merge SHA：`ec4c5316392c48947ebf2949a6652988b2182ccc`。
- 该 caller 固定调用已合并的 Playbooks Caddy owner，并在缺少执行器、目标或证据时 fail-closed；这只证明调用契约已进入 main。
- Caddy 旧副本仍不得删除：尚缺真实 UAT 运行、失败/幂等回执和删除后的完整 CI 证据。

## 5. 数据迁移、隔离恢复和升级门禁

Playbooks 现有 `web_saas_data_backup` 与 `web_saas_data_restore_verify` 已有 disposable PostgreSQL round-trip CI 证据：加密备份、checksum、隔离库恢复、schema/data fingerprint、错误密钥和占用库失败路径均有覆盖。

但以下结论必须分开：

- disposable PostgreSQL CI 通过 ≠ UAT 主机实际恢复通过；
- UAT 实际恢复通过 ≠ 真实数据库升级已授权；
- PR/CI green ≠ UAT 业务验收；
- 当前 `web_saas_data_migration` 仍以 `UNSUPPORTED_SELFHOST_MIGRATOR_CONTRACT` 阻断真实迁移；统一数据操作入口的 `adapters.json` 当前 UAT/PROD 均为空，升级演练执行器尚未注册；
- 备份实际恢复证据通过前，不得注册或 dispatch 真实升级；
- 数据库问题优先向前修复，不执行破坏性 down migration；
- 本交接周期不执行 PROD。

### 5.1 UAT→PROD 平滑升级状态机评估

设计闭环是正确的：**UAT 产生晋级资格，PROD 根据实时生产条件重新预检并消费同一构件**。UAT 演练应固定为：

`准备 → 升级验收 → 回滚验收 → 同一构件再升级重验 → 具备 PROD 晋级资格`

统一入口已经具备对应的控制顺序：

`preflight → backup → migration → promotion → verification → rollback → repromotion → final_verification`

其中 backup 必须绑定同环境 `/data/backups/web-saas/<environment>/<release-tag>/<run-id>/` 检查点和隔离恢复证据；migration 必须绑定精确版本/checksum、`dirty=false`、锁/超时、向前兼容和幂等；rollback 只回退应用并保留扩展 schema；repromotion 必须证明同一 digest、无重建、无共享服务 bootstrap、无 PROD→UAT 数据同步。

当前评估为 **控制面已具备，真实演练不具备执行条件**：

- `.github/scripts/environment-upgrade/adapters.json` 为 `{"schema":2,"uat":{},"prod":{}}`，八个真实阶段没有已审核执行器；
- disposable PostgreSQL 备份/隔离恢复 CI 不能替代 UAT selfhost web-saas 实际恢复；
- 还缺本次候选的 UAT Hybrid run、immutable tag、schema 起止版本、迁移 SHA-256、环境本地备份主机身份及脱敏业务基线；
- 因此不得 dispatch 真实 upgrade/rehearsal，不得把 fail-closed 阻断或 PR/CI green 记录为 UAT 通过，也不得触碰 PROD。

执行顺序必须是：先落 Playbooks backup/isolated-restore owner 并真实验证，再注册 UAT 执行器，完整跑通上述闭环；任何阶段异常均停止、核实实际状态并修复后，开启新 run 从准备开始重走完整演练，不能跳过或复用不匹配 receipt。

## 6. 下一位执行者操作顺序

### Step A：UAT 只读 runtime 验证

1. 从批准 CMDB artifact 获取准确 host/user/state directory。
2. 运行已合并的 Toolkit caller，固定 Playbooks SHA `94b9ca010efb1eeb62469f791a910dd361f1abae`。
3. 只执行 `gateway_verify` 或 `one_verify`。
4. 保存脱敏 run URL、target、两边 SHA、状态结果和主机是否变更。

### Step B：XConnect 安装/加入 owner

1. 复用现有 Gateway/One Role，只补 artifact、invite、CA、known_hosts、CMDB 和 receipt 契约。
2. 补负例：错误 target、错误 environment、错误 device/network、过期/已使用 invite、SSH trust failure、service/handshake failure。
3. 补幂等：已有 identity 重跑不得重建；失败不得泄露 invite、credential、私钥或 runtime state。
4. owner 合并并固定 SHA 后，再切 Toolkit caller。

### Step C：UAT 完整验证与 cleanup

依次验证 `setup → bootstrap → gateway → one → verify`，再处理 observation/desktop/cleanup。验证通过后才允许删除对应旧副本；未覆盖 caller 的脚本继续冻结。

### Step D：其他迁移批次

建议顺序：

1. XConnect existing-One 主机操作（Playbooks）；
2. XConnect Terraform/lease/provider 状态（IaC Modules）；
3. DNS/Cloudflare reconcile（IaC Modules）；
4. `platform-ops/deploy` 与 `resize` 主机健康/服务操作（Playbooks）；
5. SMTP Secret Manager provider 写入（IaC Modules）；
6. 每批完成后独立 cleanup，不跨批删除。

## 7. 交接禁区

- 不修改 PROD，不执行 PROD 迁移、升级、回滚或数据恢复。
- 不同步 PROD → UAT，不重建数据库，不 bootstrap Vault/Observability 共享服务。
- 不把 GitOps 当 CMDB；不把 IaC provider 操作写入 Playbooks；不把主机命令写回 Toolkit。
- 不以 `find` 行数减少作为迁移完成依据。
- 不以 PR merge、CI green、disposable restore 或 HTTP 200 替代真实 UAT 验收。
- 隔离恢复实际通过前，不进入真实升级；不得绕过 dirty/checksum/版本精确匹配门禁。

## 8. 追踪入口

- 总跟踪 Issue：[platform-ops-toolkit#1269](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/1269)
- Owner PR：[playbooks#574](https://github.com/ai-workspace-infra/playbooks/pull/574)
- Caller PR：[platform-ops-toolkit#1283](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1283)
- Upgrade delegate PR：[platform-ops-toolkit#1284](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1284)
- Handoff snapshot PR：[platform-ops-toolkit#1285](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1285)、后续合并快照 [#1286](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1286)
- 历史详细交接：[2026-10-04-execution-ownership-migration-handoff.md](2026-10-04-execution-ownership-migration-handoff.md)
- 下一批合同：[2026-10-05-next-execution-batches-contract.md](2026-10-05-next-execution-batches-contract.md)
- Scanner 合同：[2026-10-05-ownership-scanner-contract.md](2026-10-05-ownership-scanner-contract.md)
