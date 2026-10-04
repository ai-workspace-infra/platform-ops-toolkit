# Toolkit 执行职责迁移交接（2026-10-04）

## 目标与边界

按「归属仓库新增通用执行入口 → Toolkit 切换调用 → 验证 → 删除旧副本」完成这一批。IaC Modules 执行 Artifact Registry 镜像就绪查询与按 digest 晋级；Toolkit 选择环境、校验 UAT 发布证据、处理 Vault/OIDC、控制顺序，并核对 Cloud Run 实际服务的 digest。GitOps 继续提供目标状态。此批不涉及真实发布、DNS、数据库或主机操作。

工程依据：`xworkspace-core-skills/skills/engineering-standards/execution-ownership-migration/SKILL.md`（读取 `origin/main`），以及该 skill 引用的仓库地图。自动归属扫描只是线索，不可按 `serverless/` 目录名决定归属。

## 已完成且已验证

1. IaC Modules [PR #389](https://github.com/ai-workspace-infra/iac_modules/pull/389) 已合入 `main`，固定提交 `1a7d2e000314207d2f13901da8e15a98a9bf252b`。新增：
   - `scripts/pipeline/artifact-registry-wait.sh`：按完整镜像仓库 URI 和 tag 等待 Artifact Registry 就绪，可配置正整数次数／间隔；digest 尚在索引时沿用精确 tag 作为就绪信号。
   - `scripts/pipeline/artifact-registry-promote.sh`：按 UAT 已验收清单中的单一服务和 digest 晋级；现有 tag 指向不同 digest 时拒绝写入；写后再读并输出 `digest`。
   - `scripts/pipeline/tests/artifact_registry_release_test.sh` 与 README 契约。本地模拟及 PR `pipeline-scripts` CI 通过，未调用真实 GCP。
2. Toolkit `main` 起点为 `f461dfdc6ae55ed1f567e90d03a98d8d8bbff9d4`。已建立分支 `feature/artifact-registry-caller-cutover`，工作树 `/private/tmp/toolkit-artifact-registry-cutover`。目前该分支**只有本交接文档**；调用方及旧脚本尚未变动。
3. Toolkit 主 checkout `/Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit` 在本批检查时为干净的 `main`。IaC 主 checkout `/Users/shenlan/workspaces/ai-workspace-infra/iac_modules` 有既有未跟踪文件，务必保留；IaC PR 在独立工作树完成。

## 下一步：Toolkit 调用方 PR

这条 Artifact Registry 调用方工作已经具备 IaC 前置实现，但可排在下面的 Playbooks 优先批次之后。其工作树已创建，当前只保存交接文档；不要误报为调用方切换完成。

1. 在 `serverless-orchestrator.yml` 的 `cloud_run` job 中，在执行前 checkout IaC Modules 到 `iac_modules/`，`ref` 固定为上述 40 位 merge SHA，`persist-credentials: false`。不改变现有 UAT/PROD 选择、Vault 角色、GitOps 目标、`build → promote → wait → deploy → verify → record` 顺序。
2. 将 `Promote the UAT-accepted image by digest` 的 `run` 改为 `./iac_modules/scripts/pipeline/artifact-registry-promote.sh`。沿用 `PROMOTION_MANIFEST`、`SERVICE`、`TARGET_IMAGE`、`IMAGE_TAG`，保留 `id: promoted` 及 `digest` 输出。
3. 将 `Wait for service image in Artifact Registry` 的 `run` 改为 `./iac_modules/scripts/pipeline/artifact-registry-wait.sh`。传入 `ARTIFACT_IMAGE_REPOSITORY: <region>-docker.pkg.dev/<project>/serverless/<matrix.service>` 和 `IMAGE_TAG`，目标值仍来自现有 GitOps reader。旧的 `GCP_PROJECT_ID`、`GCP_ARTIFACT_REGISTRY_REGION`、`CLOUD_RUN_SERVICE` 不再是该执行入口的输入。
4. 更新 `.github/scripts/tests/serverless_artifact_image_wait_test.sh` 中的旧路径与输入断言；更新 `.github/scripts/tests/prod_same_digest_promotion_test.sh` 的 `promote` 路径，使其在本地可通过 `IAC_REGISTRY_TEST_ROOT` 指向 IaC 工作树、在 CI 可使用已有的 `pipeline-contract/iac_modules` checkout。保留该测试对 UAT 成功证据、PROD 不重建、占用 tag 禁止覆盖和服务 revision digest 的现有断言。`verify_cloud_run_image_digest.sh` 属于 Toolkit 发布结果核验，此批留在 Toolkit。
5. 核对 `.github/workflows/validate-release-pr.yml` 的现有 IaC checkout（`pipeline-contract/iac_modules`，当前 ref `main`）及 `scripts/ci/workflow_script_refs_verify.py` 能识别新路径。让相关 contract tests 在 PR CI 实际运行；若它们原本未在该 workflow 中被调用，加入聚焦的非变更演练步骤。无须新增 Vault workflow 或修改白名单，因为 `cloud_run` job 的 workflow 名称与身份未变。
6. 本地运行两个已有 contract tests、`workflow_script_refs_verify.py --iac-root <IaC 工作树> --playbooks-root <Playbooks 工作树>`、`workflow_gating_verify.py`、`script_ownership_verify.py` 和 `git diff --check`。PR 中写明 IaC #389 和固定 SHA。CI 全绿再合并 Toolkit 调用方。

## 再下一步：验证后清理 PR

从最新 `origin/main` 开新分支，确认全仓对两个旧路径已无 workflow 调用，再删除：

- `.github/scripts/serverless/promote_image_by_digest.sh`
- `.github/scripts/serverless/wait_for_artifact_image.sh`

同时更新或删除仅依赖旧路径的断言，并从 `scripts/ci/legacy-execution-inventory.json` 移除这两项冻结记录；不要修改其他旧脚本。执行完整调用路径、CI、负例及输出契约验证后，提交单独清理 PR。当前 `.github/scripts` 为 209 个条目，预计仅删除这两个文件后为 207；冻结候选由 11 变为 9，以实际扫描结果为准。旧副本只在新调用方合入并通过验证后删除。

## `.github/scripts` 重新评估：四个边界与下一批

本次核对的 Toolkit `main`：`.github/scripts` 共 209 个路径条目、189 个文件；其中 `tests/` 87 个、`platform-ops/` 28 个、`xconnect-lab/` 21 个、`snapshots/` 16 个、`serverless/` 13 个。冻结执行扫描列出 11 个候选，但它按目录和简单命令模式识别，既不能证明其他文件都属于控制面，也不能直接决定仓库归属。每批必须查实际 workflow、包装脚本、测试和 Vault 调用链。

| 边界 | 本批保留或承接的职责 |
| --- | --- |
| Toolkit | 工作流入口、审批、目标选择、Vault/OIDC、跨步骤顺序、发布证据与最终验收；薄适配器限于当前工作流必需部分。 |
| GitOps | 非敏感的声明式目标状态及 release 引用；不是 CMDB，也不存执行脚本。 |
| IaC Modules | Cloud、DNS、Registry、OS Login、临时防火墙等 Provider 操作及运行事实／CMDB 产出；不保存第二份手写环境配置。 |
| Playbooks Roles | 主机与服务部署、迁移、恢复和服务健康；Observability 服务部署、遥测数据迁移和健康检查均在其 Observability Role。 |

Observability 相关旧副本已在上一批完成切换／删除：Playbooks #566、#567 与 Toolkit #1260–#1263。本批无需再创建一个 Observability 安装器仓库的执行入口。

**优先批次 P1：ZITADEL 主机／服务操作。** 当前 `.github/scripts/service-deploy/zitadel.sh` 共 138 行，由 `zitadel-server.yml` 调用；它混合了 VM/OS Login/临时防火墙、Ansible 部署和公网 OIDC 健康检查，因此不能整文件平移。先扩展 Playbooks 现有 `roles/docker/zitadel` 或新增其操作 Role，承接部署后的服务健康、失败诊断和明确的主机操作输入；保留原有 PostgreSQL、PAT、masterkey 与不可破坏性初始化保护。归属 Role 需要本地模拟／语法和负例测试。再把 VM 状态、OS Login 临时凭据和临时防火墙的创建与清理抽为 IaC Modules 可复用 Provider 执行入口，并产出目标事实；保留失败时清理边界。之后 Toolkit 以已审核固定 SHA 调用，保持 GitOps 目标选择、Vault OIDC 和确认门禁，验证 `deploy` 与 `verify` 两种路径及原有 `scripts/tests/test_zitadel_server_contract.py`。只有新调用链通过 PR CI 和非变更演练后，才删除原混合脚本。原脚本里 `verify` 分支仅靠公网 OIDC 检查，需按服务健康归属纳入 Role，而 Toolkit 判断验收结果。

**后续批次 P2：XConnect 实验与 existing-One。** `xconnect-lab/deploy.sh` 729 行、`xconnect-existing-one-uat/deploy.sh` 527 行，另有 `xconnect-lab/run.sh` 270 行和 `enroll-node.sh` 176 行。`run.sh` 同时派发 Terraform 与部署阶段，`deploy.sh` 混有 SSH、Ansible、控制器登记与健康探测。先列出各阶段的输入／凭据／回滚，再分别让 IaC Modules 负责资源操作、Playbooks Roles 负责主机部署和服务验收；Toolkit 保留阶段编排。不能为了减少计数直接删除这组互相调用的脚本。

**并行准备但按依赖合并的 P3：Serverless。** 已合入的 Artifact Registry #389 归 IaC Modules；Toolkit 调用方和旧副本清理按上文继续。`sync_smtp_secrets.sh` 需把 Vault 授权与 Secret Manager 写入拆开；`verify_cloud_run_image_digest.sh` 属于 Toolkit 的发布结果证据验证，按当前合同暂留。两条初始化凭据脚本需独立核对 Vault/Provider 边界。`snapshots/`、`gitops/` 和 `tests/` 不按目录整体迁移。

每个批次固定：归属仓库先实现通用 Role/Workflow 与测试 → 合并并固定 SHA → Toolkit 切调用方与契约测试 → 验证各环境／负例／输出 → 最后单独删除旧副本。跨仓库提交必须留可追溯 PR；本次只形成接手计划，没有触发 UAT/PROD 工作流。

## 当前状态的判定

IaC 执行入口已经合入并可引用；Toolkit 尚未切换，所以旧执行脚本仍是当前运行路径。本交接文档不是 UAT/PROD 部署或运行时验收证据。接手时先 `git fetch` 核对分支与 PR 状态，再从 Toolkit 调用方步骤继续。
