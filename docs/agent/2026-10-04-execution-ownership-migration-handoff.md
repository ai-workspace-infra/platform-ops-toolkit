# Toolkit 执行职责迁移交接与评估（2026-10-04 15:31 UTC 更新）

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

## 2. 已完成且已合入批次与固定 SHA 审计（15:31 UTC 基线）

截至 2026-10-04 15:31 UTC，已完成的批次及其 CI 运行状态已全量复查完毕，相关 PR 均已合入各仓库 `main` 并取得绿色通过状态：

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
  - 新增 `zitadel_operations.yml` 入口与 `roles/docker/zitadel_operations`，支持 `verify_host` 与 `verify_public`（OIDC discovery 端点探测与健康诊断）。
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

---

## 3. `.github/scripts` 深度盘点与扫描器评估

### 当前文件结构统计
当前 Toolkit `main` 分支下 `.github/scripts` 共有 **186 个文件**（对比最初 189 个，已删除 3 个）：
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
- **后续优化计划**：在完成 P1b 后，提专用 PR 修正扫描器规则：放行 Toolkit 原生的 Vault/HTTP 只读探测与只读验收；捕获动态 SSH 与变量 curl 修改；按行为属性精确归类。

---

## 4. 后续剩余批次推进顺序与落地方案

按四个架构边界，重排后续批次优先级如下：

### 优先批次 P1b：Caddy 证书恢复（先落 Playbooks Role，再切 Toolkit 调用）
- **涉及脚本**：`.github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh`（299 行）。
- **边界划分**：
  - **Toolkit**：通过 OIDC 向 Vault 读取泛域名证书 PEM 数据（fullchain, privkey），校验证书有效期与域名匹配度。
  - **Playbooks Roles**：在 `roles/docker/caddy` 或新增 `roles/docker/caddy_certificate_restore` 中实现通用任务，接收证书内容，安全写入主机目录（严格设置 `0600` 权限），更新 Caddy TLS 配置并执行热重载或服务健康检查。
  - **Toolkit**：通过固定 Playbooks SHA 调用该 Role，验证各环境证书恢复，最终删除旧脚本。

### 后续批次 P2：Cloudflare DNS 对账（IaC Modules 承接，Toolkit 控制）
- **涉及脚本**：
  - `platform-ops_uat_dns_reconcile.sh`（347 行）
  - `platform-ops_sit_all_in_one_dns_reconcile.sh`
  - `xconnect-lab/reconcile-gateway-dns.sh`
- **边界划分**：
  - **GitOps**：提供声明式的 `EdgeRoutingConfig`（模式、权重、TTL、规范域名）。
  - **IaC Modules**：复用并扩展 IaC #388 的 `cloudflare-dns-record` 执行入口，接收规范记录列表，执行 Cloudflare DNS API 对账与 upsert。
  - **Toolkit**：读取 GitOps 路由配置，调用 IaC Modules 进行对账，校验公网解析一致性。验证后清理 Toolkit 内重复对账脚本。

### 后续批次 P3：XConnect 实验室与 existing-One 架构拆解
- **涉及脚本**：
  - `xconnect-lab/`（`deploy.sh` 729 行, `run.sh` 270 行, `enroll-node.sh` 176 行, `desktop.sh`, `node-observation.sh`, `lease.sh`, `terraform-diagnostics.py`）
  - `xconnect-existing-one-uat/deploy.sh`（527 行）
- **边界划分**：
  - **IaC Modules**：接管 Terraform 资源操作、租约生命周期（`lease.sh`）与 Terraform 异常诊断（`terraform-diagnostics.py`）。
  - **Playbooks Roles**：承接主机层 WireGuard/XRay 容器部署、节点注册、桌面配置与节点可观测性探测。
  - **Toolkit**：保留实验网生命周期阶段编排（plan -> lease -> apply -> enroll -> verify -> teardown）与审批门禁。

### 后续批次 P4：SMTP 凭据同步拆分
- **涉及脚本**：`.github/scripts/serverless/sync_smtp_secrets.sh`（145 行）。
- **边界划分**：
  - **Toolkit**：负责 Vault Token/OIDC 认证，读取 `kv/data/<env>/platform/smtp/google`，执行版本比对。
  - **IaC Modules**：提供通用的 GCP Secret Manager 写入入口（包含 API 启用安全探测、`gcloud secrets versions add / create` 幂等写入）。
  - **Toolkit**：调用 IaC 脚本完成写入，并验证 Accounts 服务的降级/就绪状态。

### 横向优化批次：GCP 管道脚本归整至 `iac_modules/scripts/pipeline/gcp/`
- 将 IaC Modules 现有的 `ensure-gcp-vm-running.py`、`register-gcp-oslogin-key.sh` 与 `gcp-temporary-ssh-access.sh` 统一规整至 `iac_modules/scripts/pipeline/gcp/`。
- 设置向后兼容软链或调用周期，全面收敛 `node-access-gcp`、`observability-server.yml` 与 `ai-aggregator-v1.yml` 中重复的 VM 临时访问逻辑。

---

## 5. 待决定事项（Open Decisions）

以下两项设计决策直接影响后续发布与 UAT/PROD 晋级，需技术负责人确认：

### 待决定项 1：Accounts 登录绕过补丁的处理（Accounts Login Bypass Policy）
- **现状与冲突**：在非生产环境（如 local/sit/uat）中，Accounts 服务的鉴权可能受到外部 IdP（Google/GitHub OAuth）或生产邮箱验证码发送限制，历史分支中存在跳过真实鉴权或模拟凭据的绕过补丁。
- **决策点**：
  - **方案 A（严格安全等价）**：坚决禁止任何代码级登录绕过。必须在 Vault 中配置受保护的测试专用真实账号密码（original-user credentials），所有 UAT 验收必须走真实的密码校验与 Session 颁发。
  - **方案 B（隔离模式绕过）**：允许在显式配置 `ENVIRONMENT_MODE=uat-isolated` 且由 GitOps 声明的环境下启用受限的模拟认证，但在晋级 PROD 前由门禁强制核验该绕过代码未编译进镜像。
- **建议**：采用方案 A。任何代码层绕过均会使 UAT 失去“防降级”与“平滑升级”的验证效力。

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
   - B0（Artifact Registry）与 P1（ZITADEL）的全部 4 个阶段（归属实现、调用方切换、验证、清理）已全部走完，相关 PR 全部合并，`main` CI 均为绿色。
   - `docs/agent/2026-10-04-execution-ownership-migration-handoff.md` 已全面重构，明确四个架构边界与后续顺序。
2. **后续推进路线**：
   - **Step 1**：创建 PR 提交本文档的更新。
   - **Step 2**：进入 **P1b 批次**，在 `playbooks` 仓库新增 Caddy 证书恢复通用 Role 及语法/本地测试；合并后固定 SHA。
   - **Step 3**：Toolkit 切换调用方至 Playbooks 新 Role，验证无误后删除旧版 `platform-ops_deploy_base_restore-caddy-certs.sh`。
   - **Step 4**：推进 P2（Cloudflare DNS 对账）及后续批次。
