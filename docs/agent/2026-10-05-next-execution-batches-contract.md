# 后续执行职责迁移合同草案（P3 / P4 / 横向收敛）

## 2026-10-07 XConnect Accounts 邀请 owner/caller 切换

`declared-network` 的 Accounts API invitation 已从混合 Toolkit bootstrap 路径切到
Playbooks owner action `xconnect-network-bootstrap`，固定 owner SHA 为
`2d326409ccfbd5f6e862c3dc08660e0ae12fb51d`。Playbooks 只消费 Toolkit 已校验的
私有请求和运行时 service token，调用 Accounts bootstrap API，并写出 mode `0600`
的私有 handoff；它不登录 Vault，也不持久化 invitation。

Toolkit 保留 GitHub OIDC、Vault role、GitOps/owner 固定 SHA、目标选择以及私有
invitation 写入。新 `xconnect-network-invite-handoff` action 只接受 Playbooks 返回的
精确 network/gateway handoff，并写入本次 run/attempt 专属的 Vault KV 路径。
`.github/scripts/xconnect-network/bootstrap.sh` 保持冻结且不再是 workflow caller；在
真实 prod/custom 声明完成 Accounts HTTP 201、精确响应核对、Vault write receipt 和
下游一次性 invitation 消费验证前不得删除。当前只有离线 mock/契约证据，未执行
Accounts API 或 Vault 写入，也不构成 UAT 完成。

## 2026-10-07 XConnect lab IaC lifecycle owner/caller 切换

`xconnect-zero-cloud.yaml` 的 Terraform preflight/prepare/apply/cleanup 已切到固定
IaC owner SHA `9570b01959396e1d0e20331205b5cb5718f5c588` 的
`xconnect-lab-lifecycle` action。owner 仅处理精确 run state、Terraform plan/apply/
destroy/output/state evidence、AWS provider facts、租约对象 CRUD 和脱敏诊断；它不
调用 Toolkit 脚本、SSH、Ansible、systemd 或 Accounts API。`run.sh` 继续承担输入、
GitOps topology、release artifact 与尚未迁移的阶段分发，旧 `prepare.py`、`lease.sh`
及 `terraform-diagnostics.py` 保持冻结，等待真实 apply/失败/cleanup UAT 后再删除。

本地 mock 已覆盖相同 plan 的 apply、私有 output、精确 state show、允许资源集合、
destroy 后空 state 与 lease create/delete；尚未执行 AWS、Terraform remote state 或
真实资源动作。外部 Gateway SSH key 仅由 Toolkit 做 mode-0600 秘密交接，实际主机
执行仍待切换到 Playbooks owner。

核对基线：Toolkit `ec7bc9b1`，Playbooks `14f6196b`，IaC `71746d06`。本文件是实码评估与后续门禁，**不是已实现、已合并或已验收记录**。P2a owner 另见 IaC #392。所有后续批次保持 owner → caller → 验证 → cleanup；不自动合并、不改变管理员权限、不读取真实凭据、不执行真实云端/主机操作。

## P3：不要整体移动 XConnect 混合脚本

当前 caller 在 `.github/workflows/xconnect-zero-cloud.yaml`：lab 使用 `run.sh` 的 validate/topology/download/preflight/prepare/apply/setup/bootstrap/gateway/one/verify/observability/node-observation/cleanup 阶段；existing One 直接调用独立 `deploy.sh`；额外节点直接调用 `enroll-node.sh`。合同测试和 runbook 也引用旧路径，caller 切换须逐一覆盖。

| 现有路径/行为 | 归属及拟拆分 | 必须保留的门禁 |
| --- | --- | --- |
| `run.sh` 的输入、ref、GitOps 校验与阶段分发 | Toolkit 薄控制适配器 | environment/run/release 固定；apply 前 backend ready；部署前 apply attempted + outputs；verify 后才开放观察窗口 |
| `run.sh` 的 Terraform init/plan/apply/output/show/destroy/state list 与 diagnostics | IaC 执行入口 | backend 身份和 Provider OIDC 分离；日志私有；失败 apply 的证据不被 cleanup 覆盖；cleanup 从实际 state 检查精确 run；destroy 后 state 空才可完成 |
| `lease.sh` 的 S3-compatible put/list/get/delete | IaC 租约状态适配器 | 显式 bucket/endpoint/prefix/run/expiry；不接管其他 run；分页完整；失败不返回 cleanup success |
| `lease.sh` 的过期判定、cleanup inputs 与 `gh api .../dispatches` | Toolkit 编排 | 校验已记录 run/ref 与 expiry；审批与 dispatch 分离；dispatch receipt 不等于资源已删除 |
| `deploy.sh` / existing-One / `enroll-node.sh` 的主机安装、identity、join/up、systemd、WireGuard 与远程健康 | Playbooks Roles | 显式 target/SSH trust、device/network/gateway identity、immutable binary/release、run 范围；幂等重跑不重建 identity；拒绝跨环境/错误 host |
| Accounts API bootstrap/invite 与 gateway owner reconciliation | Accounts 服务写入归 Playbooks 参数化 owner；Toolkit 保留 OIDC/Vault 授权、秘密交接和最终门禁；主机 join 仍由 Playbooks Roles | 不把 API success 当主机成功；invite 为一次性敏感文件；不能把 mutating invite creation 标为 non-mutating rehearsal |
| `desktop.sh` / `node-observation.sh` 的 host probe | Playbooks 受限健康入口；等待窗口/汇总留 Toolkit | timeout ≤ lease expiry；SUMMARY_ONLY / UNVERIFIED 原样传递，不转译成验收成功 |

### 复用与第一子批次

Playbooks 已存在 `deploy_xconnect_one.yml`（`roles/vhosts/xconnect_one`）、`deploy_xconnect_gateway.yml`（identity/enrollment 两阶段，`roles/vhosts/xconnect_gateway`）与 `deploy_xconnect_observability.yml`。先审查这些 Role 的输入、runtime identity 和失败语义；只补缺口，不复制一份 lab 专属同等执行实现。

建议 P3a 先收敛 One enrollment 的主机执行/健康：以明确 CMDB target 或受控 existing-host runtime binding、private invite/binary/CA 文件为输入，输出无敏感的 device/network/runtime receipt。Gateway identity/enrollment、Terraform/lease、desktop/observer 分别作为后续子批次。existing One 当前从 Vault source record 获取目标，不能在重构中用 GitOps IP 或 `NODE_ID` wildcard discovery 替代。

### 已观察风险，不能继承为新默认

- `enroll-node.sh` 先 POST Accounts bootstrap，之后才判断 `MODE=dry-run`；它会产生真实 invite，不是无变更演练。
- host discovery 使用 Name wildcard 取第一个 IP；host 缺失和 SSH 不通允许 exit 0。新 host acceptance 必须 fail closed，invitation-only 必须使用独立状态，不能叫 deployed/enrolled。
- 该脚本使用 `ANSIBLE_HOST_KEY_CHECKING=False` / accept-new；新路线必须明确可信 known_hosts 来源和失败门禁，不能静默扩大信任。
- vars 文件只在 Ansible success 后删除；新 caller 必须 always 清理。API failure body、join_uri、device credentials 和主机 state 不允许进入公开日志/artifact。
- observation 的 external-gateway 分支只等到 expiry 并返回 SUMMARY_ONLY；这不是 One 或 Gateway 数据面验收。

验收矩阵至少覆盖：fake Accounts API + fixture inventory、missing/mismatched target、错 device/network、expired/used invite、owner missing、SSH trust failure、service/handshake failure、幂等保留 identity、always secret cleanup。真实验收须记录 owner/Toolkit/binary SHA、environment/target/run、实际 Role 与 overlay handshake/private traffic；未覆盖 caller 的旧脚本保留。

### 2026-10-07 host/service caller 切换 gate

以下 gate 是下一子批次的执行清单。当前 Playbooks SHA
`2d326409ccfbd5f6e862c3dc08660e0ae12fb51d` 已有 `xconnect_one`、
`xconnect_gateway`、`xconnect_lab_runtime` Roles，但只覆盖
`gateway_identity/gateway/one/gateway_verify/one_verify`；它还没有等价覆盖旧 runner
的邀请、peer reconcile 和端到端 receipt。因此 `run.sh setup/bootstrap/gateway/one/verify`、
`xconnect-existing-one-uat/deploy.sh`、`enroll-node.sh` 仍是冻结 caller，不能以 Role
文件存在或 syntax-check 通过为理由删除。

| Gate | owner 完成条件 | 离线证据 | 真实 UAT receipt | 当前状态 |
| --- | --- | --- | --- | --- |
| H1 可信 target handoff | Toolkit 交付精确 host/user、私有 key 与预先审查的 known_hosts；Playbooks 拒绝空 target、通配发现和 accept-new | fake inventory 覆盖 missing/mismatch/host-key failure | owner SHA、target、host-key fingerprint、Ansible recap | BLOCKED：现 caller 仍有 EC2 Name wildcard 与 accept-new |
| H2 Accounts device invite | Playbooks 参数化 service owner 支持 gateway/one、固定 network/device/role/TTL，并输出 0600 handoff；Toolkit 只做 Vault token 交接 | fake HTTP 覆盖 201/409/timeout/响应绑定/always cleanup | HTTP 201、精确 network/device/role、invite consumed once | BLOCKED：现 owner action 只覆盖 declared-network Gateway bootstrap |
| H3 Gateway identity/enroll/reconcile | `xconnect_lab_runtime` 分开 identity、join、peer reconcile；已有 credential 重跑不消耗 invite，401 轮换须显式操作 | role contract + mock command 覆盖 existing/empty/401/non-401 | gateway identity 保持、signed generation、timer active | BLOCKED：缺独立 peer-reconcile/401 rotation operation |
| H4 One deploy | `xconnect_one` 消费 immutable binary、CA、一次性 invite 和精确 target，失败也删除 runner/remote invite | fake Ansible 覆盖 wrong network/device、used invite、always cleanup | joined device/network、credential valid、runtime applied | READY-PARTIAL：Role 已有，caller 仍混在 deploy scripts |
| H5 数据面验收 | Playbooks owner 返回脱敏 receipt，包含 One/Gateway status、精确 peer handshake age、TLS/SNI、private ping/HTTP；任一缺失即失败 | fixture receipt 覆盖 stale handshake/TLS/private path failure | 同一 run 的 handshake、private traffic 与 signed config receipt | BLOCKED：现 runtime Role 只有基础 status，不等价于旧 verify |
| H6 existing-One 拆分 | release 获取/校验留 Toolkit；Accounts 写归 service owner；Gateway/One 主机操作归 Roles；观察 owner 继续复用现有 action | 每个 owner 单独 mock，不调用 Toolkit 脚本 | fixed owner/binary SHA + exact host/network + H2-H5 receipts | BLOCKED：旧 527 行脚本仍混合四类副作用 |

执行顺序必须是 H1 → H2 → H3/H4 → H5 → caller 切换 → 真实 UAT → legacy
删除。H2 的 HTTP 201、H3/H4 的 Ansible success 或现有观测 action 的 SUMMARY_ONLY
均不能单独满足 H5。迁移完成前，本仓合同测试继续断言五个 lab host stage 与两个独立
legacy caller 仍在，防止只删调用来让 scanner 变绿。

## P4：SMTP Secret Manager 与 Vault 分离

唯一已发现主 caller 为 `serverless-orchestrator.yml` 的 Accounts-only SMTP sync step。它在 Cloud Run deploy 前执行，共用已校验 GitOps project 和 Google authentication。LandingZone 的 SMTP 通知读取是另一合同，不在此批次中顺手迁移。

Toolkit 保留 Vault OIDC/Token boundary、环境 KV 路径读取、404 未种凭据决议、必需 username/password 校验、project/release/run 绑定、private runtime input 和 always cleanup。IaC 提供参数化 Secret Manager executor：explicit project/secret names、private payload 文件、API/read/write 验证、值比对与版本幂等、结构化 sanitized receipt；不认识 Accounts、Vault path 或环境拓扑。

### 状态和安全合同

- Vault 404 是控制面 `not_seeded`，不自动声称 Accounts 关闭邮件；实际 readiness/config 需独立验收。已有路径缺键仍失败。
- 服务列表无权限是 unknown，不是 API disabled。默认不擅自 enable API 或改 IAM；若 API 未启用，返回真实 blocked reason，由授权操作人处理。
- legacy 的 create/add failure 可 warning + exit 0；新 owner 必须用明确 per-secret 状态区别 unchanged/created/version_added/failed，不把 exit 0 当两项都已同步。Toolkit 是否允许非生产降级，须显式 policy 与单独 receipt，不能隐式吞失败。
- 比对版本由 IaC 完成，不由 Toolkit 复制 `gcloud secrets versions access`。不能读取失败后当作空值追加版本；missing secret、no enabled version、permission denied 必须区别处理。
- 用户名/口令不进 argv、stdout、debug、digest/hash receipt 或 artifact。runtime payload parent0700/file0600，拒绝 symlink；不改变 credential 内容。各版本写入并非原子事务，两项之间失败必须返回 partial，不部署为 synced。
- 不自动销毁/禁用旧 secret version。恢复应使用已记录的版本引用和单独审查授权，不以重新读取并写旧明文实现隐式 rollback。

owner 测试须用 fake gcloud/API，覆盖 no-change、不存在、read forbidden、API unknown/disabled、create/add failure、partial success、lost response、concurrent change、payload/path/privacy。后续 caller 必须验证 receipt 的 project/environment/run/release 和 exact secret versions；实际 Accounts revision/readiness 验收后才允许 legacy cleanup。

## 横向：扫描器与 GCP access

扫描器是 review aid，不是 owner 授权依据。专用批次需测试数组 SSH、variable curl、Cloudflare 写入、Vault 控制面、gcloud describe 与镜像 digest 只读门禁；不得仅按 `/serverless/` 分 owner，也不得以抹掉 marker 降低债务数。既有执行 SHA 保持冻结，所有发现的新 legacy 单独登记并解释行为。

GCP access 先盘点所有直接/间接 caller 的 VM ensure、OS Login key、Runner /32 firewall、revoke 与失败路径；优先调用 #390/#391 的 owner。新目录整理与 caller 收敛分开评审，动态 `infra_ref` caller 未固定前禁止先移动路径。实际权限/密钥操作不作为此合同的文档验证步骤。

## 当前门禁

以上合同最初形成时 P3/P4/扫描器/GCP 均为已评估、尚未实现。后续独立进展：Playbooks #572 远端观察 owner 已合并，SHA `1308c585bbb3806b69279be678dad2feb8099699`，caller 设计中；Toolkit #1279 scanner 修正已提出且 PR checks SUCCESS，尚未合并。P3 其它部署/Provider 子批次、P4 SMTP 与 GCP access 仍未完成；没有真实新路线 UAT 或这些 legacy cleanup。各子批次继续按 immutable owner → caller → 验证 → cleanup 推进，不用独立 PR/CI 替代环境验收。动态进展以交接文档和 #1269 的实际 SHA/证据为准。
