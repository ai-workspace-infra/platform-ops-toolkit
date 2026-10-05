# Toolkit 执行职责迁移交接与评估（2026-10-05 更新）

本次核对基线：Toolkit `ec7bc9b1`（#1276）、Playbooks `14f6196b`（#570）、IaC Modules `71746d06`（#391）。下文历史批次保留其 PR 证据；代码合并、合同/模拟演练通过与真实环境验收分别记录，不以文件数量或自动 owner 标签判断迁移完成。

## 1. 架构目标与四个边界重排原则

依据 `xworkspace-core-skills/skills/engineering-standards/execution-ownership-migration/SKILL.md` 及系统仓库地图标准，彻底将通用执行逻辑剥离出控制面仓 `platform-ops-toolkit`，按以下四个职责边界重排当前及后续批次：

| 架构层级 | 仓库 | 本批与后续承接的核心职责 | 严禁成为（反模式） |
| --- | --- | --- | --- |
| **控制面与验收编排** | `platform-ops-toolkit` | 工作流入口、审批流、目标环境与版本选择、Vault OIDC/Token 授权、跨步骤依赖与执行顺序编排、部署前决议/门禁检查、发布证据收集与最终验收（包括只读的发布制品检验 `verify_cloud_run_image_digest.sh`）。薄适配器仅限于当前工作流必需部分。 | 第二份通用的 Provider、Host、Database 或 Observability 执行实现；手写环境拓扑或私有状态。 |
| **声明式目标状态** | `gitops` | 仅提供非敏感的声明式目标状态（Desired State，如 `resources/<env>/<provider>/*.yaml`）及 release 引用；为各工作流提供统一契约。 | 运行时 CMDB、执行脚本、私有环境配置或明文凭据存储。 |
| **云资源与 Provider 操作** | `iac_modules` | 执行云资源与 Provider 级别操作（Cloud resources, Cloudflare DNS, Artifact Registry, GCP OS Login / IAM 临时 SSH 访问、临时防火墙安全组、Secret Manager 写入），产出真实运行事实与 CMDB（`cmdb.json`）。 | 手写第二份环境拓扑、保留应用层配置或直接管理主机内服务。 |
| **主机与服务操作** | `playbooks` | 执行主机与服务操作（主机系统配置、服务部署、迁移、备份、恢复、服务健康探测与验收）。**关键决策**：Observability 服务本身由 Playbooks 部署，因此其遥测数据迁移和服务健康逻辑完全归属于 Playbooks 的 Observability Role，不单独放到 Observability 安装器仓库。 | 存储环境拓扑副本、硬编码每环境一份脚本、或侵入云厂商 Provider 资源创建。 |

### 固定的四步迁移顺序
所有批次严格遵循以下顺序推进，禁止跨阶段越级：
1. **新增通用 Role/Workflow**：在归属仓库（Playbooks 或 IaC Modules）实现通用、参数化、具备幂等与自愈能力、附带单元/契约测试的执行入口；PR 合入并固定 40 位 immutable commit SHA。
2. **切换 Toolkit 调用方**：Toolkit 工作流固定引用上述 SHA，保留输入参数映射、Vault/GitOps 前置校验、发布证据链与失败熔断门禁，同步更新 Toolkit 端契约测试。
3. **严格验证**：通过完整 PR CI、非变更演练（Dry-run）及负例测试，核验调用链与证据产出。
4. **删除旧副本**：在新调用方合入 main 并验证完全通过后，最后单独提 PR 删除 Toolkit 内旧执行脚本及 `legacy-execution-inventory.json` 记录，彻底防止回退。

---

## 2. 已合入批次与固定 SHA 审计

以下历史批次的代码已合入各仓库 `main`。合同与 CI 证据不代表真实云端/主机 UAT 验收；多数 PR 明确没有执行真实环境操作。

### B0: Artifact Registry 镜像发布与晋级批次
- **IaC Modules 归属实现**: [PR #389](https://github.com/ai-workspace-infra/iac_modules/pull/389)，固定提交 `1a7d2e000314207d2f13901da8e15a98a9bf252b`。
  - 新增 `scripts/pipeline/artifact-registry-wait.sh`（按仓库 URI/tag 探测就绪）与 `scripts/pipeline/artifact-registry-promote.sh`（按 digest 安全晋级，冲突时绝不覆盖）。
  - 新增契约测试 `scripts/pipeline/tests/artifact_registry_release_test.sh`，本地模拟与 CI 全绿。
- **Toolkit 调用方切换**: [PR #1264](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1264)。
  - `serverless-orchestrator.yml` checkout IaC Modules 并调用上述两个入口，保持环境变量与 digest 校验契约。
- **Toolkit 旧副本清理**: [PR #1265](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1265)。
  - 删除 `.github/scripts/serverless/wait_for_artifact_image.sh` 与 `promote_image_by_digest.sh`，从冻结清单移除，冻结候选由 11 降至 9。

### P1: ZITADEL 主机与服务操作迁移批次
- **Playbooks 归属实现（服务健康与诊断）**: [PR #568](https://github.com/ai-workspace-infra/playbooks/pull/568)，固定提交 `ada1ce1eea8a5c9b26f9049eafc0f9bdd1ffa685`。
  - 新增 `zitadel_operations.yml` 入口与 `roles/docker/zitadel_server_operations`，支持 `verify_host` 与 `verify_public`（OIDC discovery 端点探测与健康诊断）。
- **IaC Modules 归属实现（临时 SSH 与防火墙访问）**: [PR #390](https://github.com/ai-workspace-infra/iac_modules/pull/390)，固定提交 `92fa6b9c592fa76a5e5fdd66bb0737de1723f20f`。
  - 新增 `scripts/pipeline/gcp-temporary-ssh-access.sh`（VM 运行态保证、OS Login 临时密钥注册、Runner `/32` 防火墙生命周期管理与安全吊销）。
- **IaC Modules CI 测试隔离补丁**: [PR #391](https://github.com/ai-workspace-infra/iac_modules/pull/391)，固定提交 `71746d0`。
  - 修复临时 SSH 脚本测试在 GitHub Actions 虚拟环境下的隔离问题，IaC `main` CI 恢复全绿。
- **Toolkit 调用方切换（服务健康）**: [PR #1266](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1266)。
  - `zitadel-server.yml` 验证阶段接入 Playbooks 服务操作 Role。
- **Toolkit 调用方切换（临时 SSH 访问）**: [PR #1267](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1267)。
  - `zitadel-server.yml` 接入 IaC Modules 临时 SSH 脚本，Toolkit 严格保留 Vault/GitOps 解析、DNS 前置条件、动态 inventory 渲染与门禁控制。
- **Toolkit 旧副本清理**: [PR #1268](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1268)，合并提交 `5d14ee4d`。
  - 删除 `.github/scripts/service-deploy/zitadel.sh`（138 行混合脚本），冻结候选由 9 降至 8，Toolkit `main` CI 全绿。

### 历史已完成批次概览
- **Observability 批次**: Playbooks #566, #567; Toolkit #1260, #1261, #1262, #1263。
- **主机就绪度与快照/调整规格批次**: Playbooks #565; IaC #386, #387, #388; Toolkit #1250–#1259。
- **全局任务跟踪 Issue**: Toolkit [#1269](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/1269)。

### P0a：Observability local Grafana health

- Playbooks owner [#569](https://github.com/ai-workspace-infra/playbooks/pull/569)：`49b37d3a7d35610282f5986367c3853158660457`。
- Toolkit caller #1271：`a4d3217e5558bf03798c1e79457f1f72164f1e26`；cleanup #1272 已合并。
- owner、caller 与 cleanup CI，以及真实 Role 对 loopback fixture 的非变更演练通过；没有真实主机/云操作。详见 [独立记录](2026-10-04-observability-local-health-migration.md)。

### P1b：Caddy PEM restore（owner/caller 已合并，UAT 待验收）

- Playbooks owner [#570](https://github.com/ai-workspace-infra/playbooks/pull/570)：`14f6196bbf69b78d07f1adb9fb8c97bc816a485b`，9 项本地测试、Ansible syntax 和 owner CI 通过。
- Toolkit caller [#1273](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1273)：`9d9d7129b82324d02f4de93fcadb95fa9934436e`，两处 Selfhost 调用使用独立 owner checkout，不修改 release deployment playbooks ref。4 项 caller 合同与完整 PR checks 通过。
- Role 只验证/落盘 PEM、保护密钥权限与原子 generation；不重启/重载 Caddy，不声称 served TLS 已启用。
- UAT `37215201217` 与 `37215988175` 均在 Services GitHub App installation token 仓库查找阶段失败，未到 tag validator、resolver/build 或 child deployment。Observed failure 不是 tag 格式错误。
- main push `37216013410` success，但实际 deployment/acceptance jobs 全 skipped，Role 未执行。独立 HTTP 200/readiness 现状未绑定本批 tag/commit/digest，不作为本批验收。
- 主线已由 #1276（`ec7bc9b1eea38e6fdb05abb72589426c55f8c118`）将 Services 仓库错名 `postgresql.svc.plus` 修为 `postgresql`。新 UAT parent `37217324603` 最终 FAILURE（metadata `2026-10-04T16:48:51Z`）：四组 snapshot/build SUCCESS，但 summary 的 dispatch-and-wait step FAILURE；Hybrid `37217650094` ordered resource lanes FAILURE，routing verification SKIPPED。Selfhost `37217833619` success 仍仅 Prepare/summary、执行 jobs SKIPPED。不据此声称固定 Role 已运行或完整 UAT 通过；具体 lane 根因由主线继续诊断。
- 对应 Selfhost `37217892945` Bootstrap web-saas-uat 的 `Restore domain TLS state from Vault before Caddy can issue` step FAILURE；主线诊断为 TLS preparation generic failure。只记录脱敏阶段，不推测敏感字段根因、不扩大为固定 Role 已执行的验收。
- cleanup 跟踪 [#1275](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/1275) 仍 OPEN；旧 Toolkit 证书恢复脚本保留。需实际运行固定 Role、记录精确目标/证书权限/幂等与失败边界/runtime vars cleanup 后，才能单独提出删除 PR。管理员 App 权限与 Vault 凭据变更需授权操作人处理。

---

## 3. `.github/scripts` 深度盘点与扫描器评估

### 当前文件结构统计
Toolkit `ec7bc9b1` 下 `git ls-tree -r --name-only HEAD .github/scripts` 为 **189 个 tracked 文件**。下列分类数字保留 15:31 UTC 的 186 文件历史快照，不作为当前精确统计或迁移完成依据：
- `tests/`: 87 个（契约测试与模拟用例）
- `platform-ops/`: 28 个（涵盖 deploy, dns, observe, provision 适配器）
- `xconnect-lab/`: 21 个（XConnect 实验网与网关脚本）
- `snapshots/`: 16 个（快照门禁与演练）
- `serverless/`: 11 个（Serverless 编排适配器与验收）
- `gitops/`: 6 个（GitOps 读取器与校验）
- `environment-upgrade/`: 4 个（环境升级编排）
- `xconnect-network/`: 3 个（网络适配器）
- `resize/`: 3 个（规格调整前置检查）
- `lib/`: 2 个（公共脚本辅助函数）
- `xconnect-existing-one-uat/`: 1 个（原有节点部署脚本）
- `service-deploy/`: 1 个（`resolve_zitadel.py`，纯 GitOps 读取器）
- `release/`: 1 个（发布质量检查）
- `maintenance/`: 1 个（维护适配器）
- `README.md`: 1 个

### 剩余 8 个冻结候选的真实属性剖析（去伪存真）
当前 `scripts/ci/legacy-execution-inventory.json` 中记录的 8 个候选清单经深入分析，并非全部属于待迁移执行债务，需按实际行为分类：

| 脚本路径 | 当前标记所有者 | 真实代码行为与属性判定 | 处理方案 |
| --- | --- | --- | --- |
| `.github/scripts/platform-ops/provision/platform-ops_provision_initialize-agent-proxy-credentials.sh` (13 行) | `iac_modules` | **扫描器误报（属于 Toolkit）**。仅通过 curl 向 Vault HTTP API 发送请求，幂等初始化 `agent-proxy` 凭据，属于控制面凭据编排，不操作 Provider 或主机。 | 修正扫描器规则，移出债务清单，长期保留在 Toolkit。 |
| `.github/scripts/platform-ops/provision/platform-ops_provision_initialize-databases-credentials.sh` (101 行) | `iac_modules` | **扫描器误报（属于 Toolkit）**。仅用于幂等检查与补充 Vault `databases` 中的数据库密码，属于控制面安全编排。 | 修正扫描器规则，移出债务清单，长期保留在 Toolkit。 |
| `.github/scripts/serverless/verify_cloud_run_image_digest.sh` (66 行) | `playbooks` | **扫描器误报（属于 Toolkit）**。只读调用 `gcloud run services/revisions describe` 与 `docker buildx imagetools inspect --raw`，验证当前服务的 digest 是否与验收凭据一致。是 Toolkit 终态发布门禁，无状态变更。 | 修正所有者判定，移出执行债务，长期保留在 Toolkit。 |
| `.github/scripts/serverless/sync_smtp_secrets.sh` (145 行) | `playbooks` | **需拆分的混合脚本（P4）**。既包含 Vault 读取（Toolkit），又包含 GCP Secret Manager API 校验与 `gcloud secrets` 写入（IaC Modules）。 | 拆分职责：Vault 读取留 Toolkit，Secret Manager 写入迁移至 IaC Modules。 |
| `.github/scripts/xconnect-existing-one-uat/deploy.sh` (527 行) | `playbooks` | **待迁移主机操作（P3）**。包含大量 SSH 远程命令、Ansible 部署、WireGuard 与容器初始化。 | 迁移至 Playbooks 专用 Role。 |
| `.github/scripts/xconnect-lab/deploy.sh` (729 行) | `playbooks` | **待迁移主机操作（P3）**。包含 SSH、Ansible、节点接入探测等重度主机执行。 | 迁移至 Playbooks 专用 Role。 |
| `.github/scripts/xconnect-lab/enroll-node.sh` (176 行) | `playbooks` | **待迁移主机操作（P3）**。包含节点加入、SSH 密钥分发与服务启动。 | 迁移至 Playbooks 专用 Role。 |
| `.github/scripts/xconnect-lab/run.sh` (270 行) | `iac_modules` | **待拆分的编排/Provider 脚本（P3）**。兼有 Terraform 资源调度与部署阶段分发。 | Terraform 资源操作迁移至 IaC Modules，阶段编排保留在 Toolkit。 |

### 扫描器漏检项（False Negatives）原因与修复方案
`scripts/ci/script_ownership_verify.py` 目前基于静态正则检查存在明显漏检：
1. **漏检动态包装的 SSH 调用**：例如 `.github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh`（299 行）将命令包装在 `ssh_command=(ssh)`，并通过 `"${ssh_command[@]}"` 动态执行，绕过了正则 `(?:exec|sudo|command|run_gcloud)\s+)?(?:ssh|...)\s`。该脚本包含真实的远程主机文件写入与权限变更，属于 Playbooks 债务。
2. **漏检变量与数组形式的 Provider 调用**：例如 `platform-ops_uat_dns_reconcile.sh`（347 行）、`platform-ops_sit_all_in_one_dns_reconcile.sh` 与 `xconnect-lab/reconcile-gateway-dns.sh` 使用 `curl --request "${method}"` 或 `curl "${curl_args[@]}"` 调用 Cloudflare API 修改 DNS，未匹配硬编码的 `(?:-X|--request)\s+(?:POST|PUT|PATCH|DELETE)`。这些脚本属于 IaC Modules DNS 执行债务。
3. **目录粗暴判定**：现脚本对 `/serverless/` 路径一律赋予 `playbooks` 所有者，与实际边界不符。
- **本轮独立修正 PR**：[Toolkit #1279](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1279) 已补动态 SSH/Provider 数组、变量 curl、本地主机操作及 marker-removal SHA 负例；精确区分控制面行为与执行债务，不改 executor 字节。15 项本地测试、完整 PR checks 全部 SUCCESS，尚未合并。该 PR 提议冻结登记为 15 个（原 8 减 3 个误报、补 10 个旧漏检），不是 main 已合并状态或 cleanup 完成；混合 owner 提示仅为 review aid。

---

## 4. 后续剩余批次推进顺序与落地方案

按四个架构边界，重排后续批次优先级如下：

### 优先批次 P1b：Caddy 证书恢复（先落 Playbooks Role，再切 Toolkit 调用）
- **涉及脚本**：`.github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh`（299 行）。
- **边界划分**：
  - **Toolkit**：通过 OIDC/Vault 读取 PEM，选择环境和 inventory，生成 mode-0600 runtime vars，及时撤销临时 Token，并在 always 路径清理 vars。
  - **Playbooks Roles**：已由 #570 实现 host-only PEM restore；验证 leaf/key 配对与有效期、目录/密钥权限、原子 current generation 及幂等，保留 previous generation。Caddy 配置变更、reload 和 served TLS 验收是另一操作，不纳入落盘恢复的成功声明。
  - **Toolkit**：#1273 已固定上述 SHA 切换两处调用。当前下一门禁是 #1275 的真实 UAT 路线验收；旧脚本仍保留，禁止用 skip/独立端点健康替代验收后删除。

### 后续批次 P2：Cloudflare DNS 对账（IaC Modules 承接，Toolkit 控制）
- **涉及脚本**：
  - `platform-ops_uat_dns_reconcile.sh`（347 行）
  - `platform-ops_sit_all_in_one_dns_reconcile.sh`
  - `xconnect-lab/reconcile-gateway-dns.sh`
- **边界划分**：
  - **GitOps**：只提供 record intent（环境、account/zone、name/type/TTL/proxy/canonical ownership policy），不保存 realized IP 或 CMDB。
  - **Toolkit**：从 intent 与当前 run 的 CMDB 生成 explicit runtime plan，取得 Vault credentials、分发、收集 receipt 并控制服务验收顺序。
  - **IaC Modules**：#388 仅支持 UAT/PROD existing-single-A cutover/rollback/restore；不能直接替换三个 reconcile 脚本。新 P2a owner 独立提供 gateway single-A plan/apply/restore，绑定 account/zone/精确 record ID，提供 provider checkpoint/readback 与 resolver convergence。
  - **Playbooks**：需要时负责 Caddy refresh 与主机/服务健康，DNS executor 不包含 SSH/host probes。
  - **分期**：先 gateway UAT single-A upsert；随后独立合同加入 CNAME/canonical adopt-yield、SIT/multi-record。旧 UAT/SIT 隐式删除冲突重复记录不复制为默认行为；清理需冲突计划、精确 record ID 与单独授权。
  - **完成门禁**：owner 合并且固定 SHA → 逐个 caller 切换 → 合同/负例/实际 UAT → 对应旧副本删除；未覆盖的 legacy caller 保留。
  - **主线 owner PR**：[IaC #393](https://github.com/ai-workspace-infra/iac_modules/pull/393) 已合并，固定 owner SHA `a0185e61fc2b41ac4dbd40c8037016aaef1b3973`；owner-contract 与 pipeline-scripts SUCCESS。
  - **主线 caller PR**：[Toolkit #1278](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1278) 已于 `2026-10-04T16:53:21Z` 合并，merge `62ea91b6e53da44552579841aa57d35de02c1852`、head `a8e6e7f0152de76504c20ae041c76b8a867043e8`，PR checks SUCCESS。main 中 `xconnect-zero-cloud` UAT gateway DNS 已调用固定 IaC owner；旧 `.github/scripts/xconnect-lab/reconcile-gateway-dns.sh` 保留。专门新路线 UAT 与 cleanup 尚未完成，失败 Snapshot/Hybrid 的 `ec7bc9b1` head 早于该 caller，不能当作新路线验收。
  - **并行候选**：[IaC #392](https://github.com/ai-workspace-infra/iac_modules/pull/392)（ready for review，head `bbfc3aecca28c127af0c63b81657c40fdd798d0e`），新增 `scripts/pipeline/dns-reconcile.py` 和独立契约，26 项新增测试、48 项 pipeline Python 测试与 CI 37217448148 通过。仍未合并，不作为主线当前 cutover 依赖，后续需审查与 #393 的能力重叠，不再并列声称主线需等待它合并。

### 后续批次 P3：XConnect 实验室与 existing-One 架构拆解
- **涉及脚本**：
  - `xconnect-lab/`（`deploy.sh` 729 行, `run.sh` 270 行, `enroll-node.sh` 176 行, `desktop.sh`, `node-observation.sh`, `lease.sh`, `terraform-diagnostics.py`）
  - `xconnect-existing-one-uat/deploy.sh`（527 行）
- **边界划分**：
  - **IaC Modules**：接管 Terraform 资源操作、租约对象存储 CRUD 与 Terraform 异常诊断（`terraform-diagnostics.py`）；`lease.sh` 的过期 cleanup dispatch 与阶段审批保留 Toolkit，不能整体搬移混合脚本。
  - **Playbooks Roles**：承接主机层 WireGuard/XRay 容器部署、节点注册、桌面配置与节点可观测性探测。
  - **Toolkit**：保留实验网生命周期阶段编排（plan -> lease -> apply -> enroll -> verify -> teardown）与审批门禁。
  - **本轮细化**：优先复用现有 One/Gateway/Observability Roles；invite-only、观察 SUMMARY_ONLY 与主机验收分别记录。详见 [下一批合同草案](2026-10-05-next-execution-batches-contract.md)。P3 部署/Provider 拆分仍未完成。
  - **远端观察 owner 子批次**：[Playbooks #572](https://github.com/ai-workspace-infra/playbooks/pull/572) 已于 `2026-10-04T16:54:47Z` 合并，固定 owner `1308c585bbb3806b69279be678dad2feb8099699`。Observability operations Role 新增 `xconnect_remote_observation`，13 项 tests + syntax passed，remote role-contract/observability role-contract/gitleaks CI SUCCESS。当前进入 Toolkit caller 设计，lease/window/expiry/验收控制留 Toolkit，远端只读观察委托 Playbooks；旧 remote observation 副本保留，caller 路线 UAT 后才单独 cleanup。无真实主机观察验收。

### 后续批次 P4：SMTP 凭据同步拆分
- **涉及脚本**：`.github/scripts/serverless/sync_smtp_secrets.sh`（145 行）。
- **边界划分**：
  - **Toolkit**：负责 Vault Token/OIDC 认证，读取 `kv/data/<env>/platform/smtp/google`，生成 private runtime payload、控制降级 policy 与 always cleanup。
  - **IaC Modules**：提供通用的 GCP Secret Manager 读写/比对入口（API 状态探测、`gcloud secrets versions add / create` 幂等写入与明确 receipt），默认不擅自 enable API 或改 IAM。
  - **Toolkit**：调用 IaC 脚本完成写入，并验证 Accounts 服务的降级/就绪状态。
  - **本轮细化**：不得继承 legacy 的 warning/exit0 为 synced；partial failure 与 invitation/readiness 等独立门禁详见 [下一批合同草案](2026-10-05-next-execution-batches-contract.md)。P4 尚未实现。

### 横向优化批次：GCP 管道脚本归整至 `iac_modules/scripts/pipeline/gcp/`
- 将 IaC Modules 现有的 `ensure-gcp-vm-running.py`、`register-gcp-oslogin-key.sh` 与 `gcp-temporary-ssh-access.sh` 统一规整至 `iac_modules/scripts/pipeline/gcp/`。
- 设置向后兼容软链或调用周期，全面收敛 `node-access-gcp`、`observability-server.yml` 与 `ai-aggregator-v1.yml` 中重复的 VM 临时访问逻辑。

---

## 5. 待决定事项（Open Decisions）

以下两项设计决策直接影响后续发布与 UAT/PROD 晋级，需技术负责人确认：

### 待决定项 1：Accounts 安全修复的交付方式
- **现状**：Accounts 存在一个已确认的真实安全缺陷，修复补丁与回归测试已由会话私下交付给技术负责人。该缺陷在公开仓库的 PR、Issue 和文档中**不记录细节**。
- **决策点**：由技术负责人决定在 Accounts 仓库以何种非公开流程（私有安全通告、私有分支）合入并发布，以及是否需要在 PROD 之前先修复。
- **说明**：这与 UAT 验收无关。UAT 验收必须使用 Vault 中受保护的真实原用户凭据，走真实登录，不得用任何代码级绕过替代。

### 待决定项 2：UAT 验收分支处理与 PROD 晋级条件（Branch `claude/modest-lamport-y9vmc5` & Promotion Evidence）
- **现状与漂移**：
  - 分支 `claude/modest-lamport-y9vmc5` 包含了 UAT 核心验收引擎 `.github/scripts/serverless/uat_acceptance.py`（895 行）与测试用例，但该分支已明显落后于 `main`（自数据操作重构 `0cee960f` 与 PR #1239 后产生大量冲突），且未创建独立可评审的 PR。
  - 核心阻断：真实的 UAT 晋级 PROD 凭据链目前因 Vault 缺少受保护的原始用户凭据（original-user password），以及数据库缺少受控的非空真实订阅样本数据，导致晋级门禁（`smooth_upgrade`, `original_user_login`, `subscriptions_preserved`）处于 `BLOCKED` 状态。**当前 PROD 严禁执行晋级发布**。
- **决策点**：
  - 1. 是否立即从当前干净的 `main` 重新提取 `uat_acceptance.py`，拆解为聚焦的 PR 并补齐契约测试？
  - 2. 明确 Vault 凭据注入与 UAT 脱敏订阅样本数据的归属人与注入时间表。

---

## 6. 当前结论与后续行动路线

1. **基线状态确认**：
   - B0（Artifact Registry）、P1（ZITADEL）、P0a（Grafana local health）的 owner/caller/cleanup 已合并且合同/非变更演练通过；不扩大为真实环境 UAT 验收。
   - `docs/agent/2026-10-04-execution-ownership-migration-handoff.md` 已全面重构，明确四个架构边界与后续顺序。
2. **后续推进路线**：
   - **Step 1**：（已完成）本文档更新已由 #1270 合入，本次仅做事实纠正与经验补充。
   - **Step 2**：（owner/caller 已完成）P1b #570/#1273 已合并；#1276 已修复 Services repo 错名，但 run `37217324603` 最终 FAILURE。真实 Role UAT 与 cleanup 仍未验收，在 #1275 跟进固定 Role 实际执行证据，旧副本保留。
   - **Step 3**：（owner/caller 已合并）#393/#1278 已完成 gateway single-A 固定 owner 接线。下一门禁为专门新路线 UAT/receipt；未验收不得 cleanup，未覆盖的 DNS legacy 均保留。
   - **Step 4**：按 P2b canonical/SIT、P3 XConnect、P4 SMTP 和横向 GCP access/扫描器任务分批推进。每一批先核对实际执行与全部 caller，不直接复制混合脚本。

---

## 7. 经验教训（本轮复盘）

1. **合并先于 CI 结束**：`Validate Release PR` 可能在 PR 被合并时仍在运行。删除旧副本之前，必须核对调用方变更那次运行的最终结论（本轮 #1267 合并后其完整运行结果为 success，随后才提交 #1268）。
2. **PR 分支上的后续提交可能没进合并结果**：IaC #390 合并时用的是修复前的提交，测试环境隔离的修复没有进入 `main`，需要 #391 补上。合并后应核对 `main` 与分支 head 的差异。
3. **行为测试跟随执行者**：执行入口及其行为测试放在归属仓库（IaC `scripts/pipeline/tests/`、Playbooks `tests/`），其 CI 会在脚本变更时直接测到；Toolkit 只保留接线、顺序和固定 SHA 的契约测试。
4. **固定 SHA 使归属仓库可以安全重排**：Toolkit 固定合并提交后，IaC/Playbooks 之后调整目录结构不会影响已固定的调用方；但未固定的调用方（如 `selfhost-orchestrator.yml` 的动态 `infra_ref`）不能先移动路径。
5. **Projects 看板**：当前会话无 GitHub Projects v2 接口，进度记录在 Issue #1269，需在看板中手动添加。

---

## 8. 2026-10-05 交接快照（最新批次与当前统计）

### 8.1 最新合入批次与固定 SHA 审计（截至 2026-10-05 08:26 UTC+8）

在 2026-10-04 基线之后，主线继续推进了 XConnect 运行时委托、网关 DNS 路由与扫描器行为升级等关键批次，相关 PR 均已合入各仓库 `main`：

1. **Playbooks #574（UAT XConnect 运行时 Owner）**:
   - 合并提交：`94b9ca010efb1eeb62469f791a910dd361f1abae`
   - 实现内容：新增 `xconnect-lab-runtime.yml` 与 `roles/vhosts/xconnect_lab_runtime`，将 Gateway 与 One 节点的 WireGuard/XRay 运行时验证与系统服务操作收敛至 Playbooks。
   - 包含前期 Playbooks #572 / #573（`1308c58`, `b6fc23c`），新增 XConnect 远端观察角色与运行时契约测试。
2. **Toolkit #1283（UAT XConnect 运行时控制面 Caller）**:
   - 合并提交：`8fd8693a`
   - 实现内容：新增 `.github/workflows/xconnect-runtime-control.yml`，默认固定引用 Playbooks #574（`94b9ca0`）。遵循控制面边界，仅负责参数校验、从 Vault 获取临时 SSH 身份、目标选择与 Ansible 调度；首期暴露只读 `gateway_verify` 与 `one_verify`。
3. **IaC Modules #393（网关 Single-A DNS Owner）**:
   - 合并提交：`a0185e6`（实现 `55add6a`）
   - 实现内容：在 IaC Modules 新增受保护的 `cloudflare-gateway-single-a.sh` 脚本与契约测试，接管网关 DNS 记录维护。
4. **Toolkit #1278（网关 DNS 路由 Caller 切换）**:
   - 合并提交：`62ea91b6`
   - 实现内容：将 XConnect 网关 DNS 对账切换至 IaC Modules #393 固定入口。
5. **Toolkit #1279（扫描器分类器升级与真实债务冻结）**:
   - 合并提交：`f9d89561`
   - 实现内容：重构 `scripts/ci/script_ownership_verify.py`，彻底修复间接变量与数组调用（如 `"${ssh_command[@]}"`、`curl "${curl_args[@]}"`）的漏检缺陷；剔除控制面 Vault 凭据初始化误报与只读镜像验证误报；将真实遗留执行清单精确更新为 15 项。
6. **Toolkit #1280 & #1281（网关配置与远端观察委托）**:
   - #1280 对齐 UAT GitOps 网关 release 默认配置；#1281 将节点观察委托给 Playbooks 远端观察角色。

---

### 8.2 当前资产与债务统计（2026-10-05 盘点）

- **`.github/scripts` 文件总数**：**190 个**（包含环境升级测试与委托骨架）。
  - `tests/`: 91 个
  - `platform-ops/`: 28 个
  - `xconnect-lab/`: 21 个
  - `snapshots/`: 16 个
  - `serverless/`: 11 个
  - `gitops/`: 6 个
  - `environment-upgrade/`: 5 个
  - `xconnect-network/`: 3 个
  - `resize/`: 3 个
  - `lib/`: 2 个
  - `xconnect-existing-one-uat/`: 1 个
  - `service-deploy/`: 1 个
  - `release/`: 1 个
  - `maintenance/`: 1 个
  - `README.md`: 1 个
- **冻结遗留执行清单（`scripts/ci/legacy-execution-inventory.json`）**：共 **15 个候选**（全部处于冻结状态，杜绝新增债务）：
  1. `.github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh` (playbooks)
  2. `.github/scripts/platform-ops/dns/platform-ops_sit_all_in_one_dns_reconcile.sh` (iac_modules)
  3. `.github/scripts/platform-ops/dns/platform-ops_uat_dns_reconcile.sh` (iac_modules)
  4. `.github/scripts/serverless/sync_smtp_secrets.sh` (iac_modules)
  5. `.github/scripts/xconnect-existing-one-uat/deploy.sh` (playbooks)
  6. `.github/scripts/xconnect-lab/deploy.sh` (playbooks)
  7. `.github/scripts/xconnect-lab/desktop.sh` (playbooks)
  8. `.github/scripts/xconnect-lab/enroll-node.sh` (playbooks)
  9. `.github/scripts/xconnect-lab/gateway.sh` (playbooks)
  10. `.github/scripts/xconnect-lab/lease.sh` (iac_modules)
  11. `.github/scripts/xconnect-lab/prepare.py` (iac_modules)
  12. `.github/scripts/xconnect-lab/reconcile-gateway-dns.sh` (iac_modules)
  13. `.github/scripts/xconnect-lab/remote-client-observation.sh` (playbooks)
  14. `.github/scripts/xconnect-lab/remote-gateway-observation.sh` (playbooks)
  15. `.github/scripts/xconnect-lab/run.sh` (iac_modules)

---

### 8.3 未完成项状态判定（明确标注：未验收 / 未删除）

根据四步迁移规则（“新增通用 Role/Workflow → 切换 Toolkit 调用方 → 验证 → 删除旧副本”），未经过真实环境端到端验证的链路，一律不得删除旧脚本：

| 迁移领域 / 批次 | 当前 Owner 状态 | 当前 Caller 状态 | 当前验收与清理状态 | 遗留副本处理决策 |
| --- | --- | --- | --- | --- |
| **XConnect 运行时操作（P3）** | **已完成**：Playbooks #574 已合入（SHA `94b9ca0`）。 | **已完成**：Toolkit #1283 已合入（工作流 `xconnect-runtime-control.yml`）。 | **未验收 / 未删除**：尚未在真实 UAT 环境执行带有真实 CMDB/主机参数的验收演练，无通过收据。 | **全部保留**：`.github/scripts/xconnect-lab/`（`deploy.sh`, `desktop.sh`, `enroll-node.sh`, `gateway.sh`, `lease.sh`, `prepare.py`, `remote-*.sh`, `run.sh`）及 `xconnect-existing-one-uat/deploy.sh` 严禁提前删除。 |
| **XConnect 网关 DNS（P2/P3）** | **已完成**：IaC Modules #393 已合入（SHA `a0185e6`）。 | **已完成**：Toolkit #1278 已切换。 | **未验收 / 未删除**：缺少基于真实 Cloudflare 解析对账的 UAT 证据。 | **保留**：`xconnect-lab/reconcile-gateway-dns.sh` 继续保留。 |
| **Caddy 证书恢复（P1b）** | **已完成**：Playbooks #570（`roles/docker/caddy_certificate_restore`）已合入。 | **进行中**：Toolkit caller 处于 PR #1284，正进行 fail-closed 合同与测试完善。 | **未验收 / 未删除**：UAT 运行与验收证据尚未产出。 | **保留**：`platform-ops_deploy_base_restore-caddy-certs.sh`（299 行）必须保留，待新链路实测通过后再提清理 PR。 |
| **SIT/UAT 规范 DNS 对账（P2b）** | **规划中**：待扩展 IaC Modules DNS 执行器。 | **未切换**：仍使用 Toolkit 旧脚本。 | **未验收 / 未删除**。 | **保留**：`platform-ops_uat_dns_reconcile.sh` 与 `platform-ops_sit_all_in_one_dns_reconcile.sh` 保持现状。 |
| **SMTP 凭据同步拆分（P4）** | **规划中**：Vault 读留 Toolkit，GCP Secret Manager 写归 IaC Modules。 | **未切换**：仍使用混合脚本。 | **未拆分 / 未验收 / 未删除**。 | **保留**：`serverless/sync_smtp_secrets.sh` 保持现状。 |

---

### 8.4 下一步核心行动指令

1. **UAT 部署验证推进（Sub Agent 2 负责）**：
   - 针对 Toolkit #1283 的 `xconnect-runtime-control.yml` 及相关 UAT 编排，设计受控的只读验证与演练。
   - 收集真实运行时健康证据与日志，输出明确的验收判定。
2. **进度持续同步（Sub Agent 3 负责）**：
   - 持续将 #574/#1283 合入、15 项遗留资产状态、“未验收/未删除”审计结果同步回 Issue #1269。
3. **主线迁移继续推进**：
   - 修复并推进 PR #1284（完善执行权限位与 fail-closed 契约测试），打通 Caddy 证书恢复调用方。
   - 保持“新增通用 Role → 切换 Caller → 验证 → 删除旧副本”铁律，严禁单纯为了削减文件计数而静默删除未经验收的脚本。
