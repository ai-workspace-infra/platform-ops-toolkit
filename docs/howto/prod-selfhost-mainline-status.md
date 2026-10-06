# PROD Selfhost 主线交付状态（2026-10-07）

## 主线与边界

GitOps 声明 → IaC 资源/CMDB → Playbooks 持久盘、主机与新空库 schema → Accounts migratectl 用户/身份逻辑复制及完整业务数据 owner → 全业务一致性与单写者回执 → Edge Gateway API 入口切换 → 生产业务验收。

- `xworktech.com` 保留品牌/法律/支持与上架审核材料；`console.svc.plus` 保留控制台入口。
- `accounts.svc.plus` / `billing.svc.plus` 通过模式限定 CNAME 与原始 Host Worker Routes 接入 Edge Gateway。
- Serverless 是 Cloud Run + PROD Supabase；Selfhost 是 `open-platform-prod / web-saas-prod` all-in-one + PostgreSQL。
- PROD Supabase 为专用只读来源；按规范化 email 匹配，PROD Proxy UUID、身份、订阅、额度、账本保留。身份复制不能替代全业务一致性。
- 日常资源部署使用 GitHub OIDC/Vault/WIF。首次 bootstrap 或权限合同修复是独立的一次性操作，不以个人 GCP 登录作为日常发布前置。

## 已确认的资源事实

GitOps [#391](https://github.com/ai-workspace-infra/gitops/pull/391) 已合并：`resources/svc.plus/prod/gcp/web-saas.yaml`，STANDARD e2-medium、独立 50 GB 数据盘、删除保护与 OS Login；沿用 `terraform/prod/svc.plus/gcp-cloud/xworktech/web-saas/terraform.tfstate`。

- [首次 plan 37458022020](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37458022020)：审批环境 `production` 与既有 `prod` WIF claim 不匹配。
- [对齐 plan 37460508241](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37460508241)：既有 `prod` OIDC 成功；8 新增、0 修改、0 删除。
- [apply 37461248828](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37461248828)：OIDC 成功，网络/子网/独立盘创建；防火墙权限、Organization Policy API 和外网 IP 策略阻挡后续资源，VM/CMDB 未完成。
- [增量 plan 37478158368](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478158368)：固定 IaC/GitOps SHA 与既有 OIDC 成功，5 新增、0 修改、0 删除，保留已创建资源。
- [增量 apply 37478514735](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37478514735)：仍因 `orgpolicy.googleapis.com` 未启用及 `compute.firewalls.create` 缺失失败；没有新建 VM。plan 成功不代表创建授权已生效。

[Toolkit #1325](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1325) 已合并，将 Selfhost 控制器的 PROD 审批环境统一为 `prod`，沿用已配置 required reviewer。没有修改 WIF subject、IAM 权限或现有 Terraform state。

## 资源 bootstrap 修复的具体合同

一次性 bootstrap principal 需核对并收敛现有 `github-actions-prod@open-platform-prod.iam.gserviceaccount.com` 的项目角色。既有 IaC identity bootstrap 声明包含 `roles/compute.securityAdmin`，但实际 apply 未具备 `compute.firewalls.create`；源码声明不是实际授权证明。

1. 用具备权限的 bootstrap principal 核对现有 IAM，按现有声明补齐项目范围的防火墙管理能力。
2. bootstrap 启用 `orgpolicy.googleapis.com`；外网 IP 策略由组织策略管理员按固定 GitOps allowlist 收敛，只允许声明的实例，不放开全部实例。
3. 确认日常 runtime identity 对项目、CMDB 与 OS Login 的能力；不得授予日常 deployer 组织级管理员权限作为快捷修复。
4. 使用同一资源 state 做增量 plan，保留已创建网络/子网/盘；删除/替换即停止。仅在 plan 审查通过后重新 apply。

bootstrap Vault 记录只有项目 ID；本次使用用户明确选择并续期的一次性账号完成修复，凭据仅走运行时。日常 deployer 不自行提权，日常资源发布继续使用 GitHub OIDC。

用户已完成一次性账号登录并授权继续；`identity` IAM/API 目标已真实收敛，
state serial 8 → 8、保护资源指纹一致，三个目标均为 no-op。统一 Shell 控制入口自动准备固定
IaC/GitOps 源码，无需填写占位 checkout 路径。操作说明见
[`scripts/cloud/bootstrap/gcp/PROD-SELFHOST.md`](../../scripts/cloud/bootstrap/gcp/PROD-SELFHOST.md)。
分 `identity`、`external-ip` 两个阶段，分别 plan → 审查摘要 → apply → 再次 plan 验证 no-op。
仅调用固定 IaC owner；沿用原 state，拒绝删除/替换与越界写入，不改变日常 OIDC 链。
旧声明与现有 Vault bucket 的差异由已合并的
[GitOps #394](https://github.com/ai-workspace-infra/gitops/pull/394) 对齐；不迁移 bucket 或 state key。
实际修复合同源自 [IaC #401](https://github.com/ai-workspace-infra/iac_modules/pull/401)，现统一为 Shell owner，
控制入口固定该 owner 与声明 SHA，不使用可变 main 作为执行源码。
外网策略实查发现旧项目策略的 parent 为数字项目 ID，且有旧实例许可。
初始计划因 parent ForceNew 被正确拒绝；GitOps #395/IaC #403 保留旧许可、
声明数字父级、在原 state 接管策略，只新增 web-saas-prod 许可。
2026-10-07 外网策略已实际收敛：原资源 state serial **4 → 5**，保护资源指纹一致；
只 update 原策略，保留 `open-platform-prod` 旧实例许可并新增 `web-saas-prod`，无删除/替换。
批准计划摘要为 `5755a064184316dabcdc5b2a6c3d9762885b1db89f87f876ae8f452863cdc2bf`。
两份 bootstrap 回执均为 `converged`、`database_cutover_approved=false`。
日常资源 [OIDC plan 37493269747](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37493269747)
已成功，**4 新增、0 修改、0 删除**（VM、两条防火墙与 OS Login），固定 IaC `ee876e29101d251ed19fadb00a3a3f0bcd1987d6` 与 GitOps
`f5083eb7c60d187a648d757d87953ffb59a7e056`，沿用原资源 state。
[资源 apply 37493634930](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37493634930)
实际完成 **4 新增、0 修改、0 删除**，`web-saas-prod` 已 RUNNING，STANDARD、删除保护和 OS Login 开启，独立数据盘验证成功。
该运行在后续 CMDB 生成阶段失败；资源已创建不能等同整条流水线成功。
[IaC #404](https://github.com/ai-workspace-infra/iac_modules/pull/404)、[#405](https://github.com/ai-workspace-infra/iac_modules/pull/405)、[#406](https://github.com/ai-workspace-infra/iac_modules/pull/406)、[#407](https://github.com/ai-workspace-infra/iac_modules/pull/407) 已合并：校验精确 WIF principal，查询指定项目的 OS Login API，并只记录 HTTP 状态、异常类型或账户数量，不输出 token/profile/keys。
[apply 37497921330](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37497921330) 为 0/0/0，但 profile 解析仍失败；未凭猜测扩大 IAM 或登记密钥。
诊断 owner 固定 `4d7f2eeb4cfef7a62427296d25c8e127fccaae6c`，
[plan 37500096383](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37500096383) 已成功且无变更；
[apply 37500322590](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37500322590) 为 0/0/0，但 API 返回没有 POSIX 账户列表。
[IaC #408](https://github.com/ai-workspace-infra/iac_modules/pull/408) 补齐首次 profile 初始化：仅精确 WIF 下缺少 POSIX 时导入未使用的 1 分钟公钥，私钥在导入前删除、公钥立即撤销，之后重新查询；撤销失败拒绝 CMDB。43 项 renderer 与 Shell 合同检查和 CI 已通过，已合并；固定 owner `b2ebd57ae10b34b0c72af48acc95fe0f95da0fec` 的 [plan 37501153551](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37501153551) 为零变更，
[apply 37501354395](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37501354395) 整条成功，0 新增/0 修改/0 删除，持久盘验证、CMDB 生成、S3 发布和 artifact 附件均成功。
`gcp-prod-web-saas-inventory` artifact `11430250658`，摘要 `sha256:9cf10d6e659d22acb0602fd3e490921545b88b7fff7f602277782fe9870aec2d`。
资源阶段已有真实证据；主机/DB 初始化与主库切换未开始。

Accounts 原生初始化构件：`ghcr.io/ai-workspace-services/accounts:sha-ddee4b01778fd1d1d644a1bc936624c81ec76093`，
manifest digest `sha256:feabb7179713ff57914ad20e2afc6816414672edf7d480d6035e2d9c667b6f30`，
SQL SHA256 `842cef3beb98ef819dc854ecdf5f85683233641a0cd85a9156b30ad59f7e0206`。
CI 发布证据不等于目标主机已拉取、初始化或全业务数据一致。

## PROD 原生待机调用方

Playbooks [#593](https://github.com/ai-workspace-infra/playbooks/pull/593) 与
[#594](https://github.com/ai-workspace-infra/playbooks/pull/594) 已合并主机待机 role 和固定版本 action；
70 项本地数据合同检查及 CI 的独立盘/PostgreSQL 17 检查通过。
Playbooks [#595](https://github.com/ai-workspace-infra/playbooks/pull/595) 增加生产数据目录挂载前的
镜像二进制资格检查，以及私有 known-hosts、关闭 SSH 长连接的独立 runner 合同。它只从固定 GitOps compose
投影 PostgreSQL，验证独立盘、空库资格与暂停的应用/CD 写者，不初始化业务 schema 或插入数据。
IaC [#409](https://github.com/ai-workspace-infra/iac_modules/pull/409) 已合并限时 OS Login/runner `/32`
访问 action，按原 CMDB 摘要和实际 VM/盘事实绑定同一 run/attempt，失败也必须撤销访问。

现有 `selfhost-orchestrator.yml` 新增 `operation=native-standby`，没有增加 dispatch 输入数量。
仅允许不可变 `v*` tag、PROD/GCP/xworktech/web-saas/svc.plus、在线模式及 `dns_mode=none`。
它校验经过审阅的成功资源 run、workflow/commit/tag/attempt、artifact ID/ZIP digest、原始
CMDB 与 inventory 摘要；只将原 artifact 重新附件到已批准的 Selfhost workflow，不手写 CMDB。
随后调用固定 IaC 与 Playbooks owner，通过真实主机检查和临时访问撤销后才发布待机回执。
`schema_initialized=false`、`database_cutover_approved=false`；旧 UAT `deploy+init` 守卫保留，
不能把此中间阶段视为数据库初始化、全量复制或生产发布完成。

SSH 收紧计划 [37509129291](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37509129291)
虽为 0 新增/1 修改/0 删除，却只新增内网范围、保留旧默认元素；apply
[37509812845](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37509812845)
在审批前已取消，未执行资源更改。
[Google provider 7.46.1 的 diffSuppressSourceRanges](https://github.com/hashicorp/terraform-provider-google/blob/v7.46.1/google/services/compute/resource_compute_firewall.go)
会在一个元素改为一个元素时抑制默认 `0.0.0.0/0` 的删除。
GitOps 将相同内网 `/24` 表达为两个 `/25`，以便计划明确移除公网默认范围；IaC 的访问前检查
还必须核对实际防火墙无公网范围。复核 [plan 37510472481](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37510472481)
明确删除 `0.0.0.0/0` 并加入两个内网 `/25`；
[apply 37510999229](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37510999229)
整条成功，0 新增/1 修改/0 删除，保护盘、CMDB、S3 与 artifact 均成功。
原始 artifact `11435337628`，ZIP 摘要
`sha256:a25f787b3f6c3305cdf51fca4aefeb20f716991e9310b309cfbd0de01f688bc3`；
CMDB 与 inventory 字节保持一致。控制配置已固定这份接受证据；未接受的资源回执会拒绝待机部署。
固定 caller 已随 Toolkit [#1331](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1331)
发布为 `v2026.10.07-r1`。首次真实 [native-standby 37512354869](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37512354869)
通过原始资源 artifact、OIDC/Vault 与 IaC 临时访问检查，并完成 Docker 安装；随后在现有容器检查处
因新版 Docker 的小写 `error: no such object` 被旧守卫误判而停止。失败发生在数据盘准备之前，
PostgreSQL 未启动，业务 schema/数据未写入，IaC 密钥与临时防火墙撤销成功，没有发布成功待机回执。
Playbooks [#596](https://github.com/ai-workspace-infra/playbooks/pull/596) 只接受精确目标、退出码 1 的
大小写规范化“对象不存在”消息，其他 Docker/权限错误继续拒绝；完整 inspect 输出隐藏以保护容器环境变量。
四个新增回归检查与独立盘/PostgreSQL 17 CI 通过，调用方固定新 owner 重试。
源码、CI 和资源接受均不能替代主机/数据库验收。

第二轮 [37517922011](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37517922011)
使用 `v2026.10.07-r2`，已准备、挂载并验证独立盘，固定镜像的二进制资格为 PostgreSQL 17。
容器已创建但持续重启，30 次就绪检查未通过；业务 schema/全业务复制未开始，没有成功待机回执，
IaC 临时访问撤销成功。Playbooks [#598](https://github.com/ai-workspace-infra/playbooks/pull/598)
修复 nested PGDATA 的 bind 父目录权限：从精确镜像解析 UID/GID，仅修改真实非符号链接父目录，
保持 `0700`，不递归处理、不移动/删除/重建现有数据库。官方入口只 chown `PGDATA`，
不处理 root 所有的 bind 父目录；CI 37520394869 已在一次性 PostgreSQL 17 上复现权限失败并验证同容器恢复，
运行回执仅保留原始私有日志中的权限失败布尔值，不发布数据库日志。Toolkit #1334 已合并，`v2026.10.07-r3` 触发 [37520882685](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37520882685)，该轮最终就绪失败；第四轮实际成功验收见后文。

原生 schema owner Playbooks [#597](https://github.com/ai-workspace-infra/playbooks/pull/597) 已合并；
默认预演、缺失库预演不创建 DB，显式 apply 运行固定 Accounts 镜像中的 `migratectl init`、覆盖服务入口。
不会启动应用、读来源、seed 或 reset，失败保留新空库。Toolkit [#1333](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1333)
独立数据审批与真实待机证据调用方已合并，CI 已通过；第四轮真实待机接受字段为 true，生产审核配置尚待补齐，
尚未执行初始化。现有生产数据脚本要求 `prevent_self_review=true`，当前配置仍为 false、唯一审核人与
触发人相同；已请求独立审核，未修改环境保护或静默削弱原数据守卫。

第三轮 [37520882685](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37520882685)
使用 `v2026.10.07-r3`，父目录所有权修正已执行，但容器仍重启、就绪失败；临时访问撤销成功，
仍无成功待机回执、业务初始化或数据复制。真实 localhost Ansible 已复现另一个凭据渲染缺陷：
未命名的 `include_vars` 覆盖任务级待机字典，实际得到 32 个公共键、空 PostgreSQL 密码。
Playbooks [#599](https://github.com/ai-workspace-infra/playbooks/pull/599) 将 tuning defaults 隔离进 namespace，
真实 renderer 验证恰好两条 PostgreSQL 键和原样口令。只允许已有匹配 owner/GitOps/image、
容器密码缺失、真实 PGDATA 空目录、无 PG_VERSION 时修复凭据并重建同镜像容器；
既有集群或无 ownership marker 一律拒绝，无数据文件删除/迁移/reset。
诊断输出仅固定状态、布尔值和已知错误代码，不含原日志或环境值；实际生产接受须再跑新固定版本。

Billing [#44](https://github.com/ai-workspace-services/billing-service/pull/44) 已合并
`cloud_vendor_costs` 独立增量 SQL 与 checksum manifest，版本边界 `2026100601 → 2026100701`；
PR/main PostgreSQL 17 CI 和 main 镜像 Pipeline 均成功，主分支源码 `5b7285bf49af12983027f7624d196ab3f2b1804f`。
SQL digest `a7133f3ef2ea9013a055cfd1442a7488d2b837f289e0f5d9b61624d4fde9bc53`，
验证 12 个原生字段、零 seed、索引/唯一键/upsert 与重复 DDL 拒绝。它只增加 Billing 自有表，
不重放共享 Accounts 表；实际 bounded migratectl owner 集成/执行仍待完成，全业务一致性必须覆盖 52+1 表。

## 尚待完成的代码与运行门槛

| 项目 | 状态 |
| --- | --- |
| PROD `deploy+init` 支持 | GitOps #393 的 PROD Doco-CD 与 `/data/postgresql` bind、Playbooks #592 的独立盘/精确 CMDB/空库 owner 已合并；Linux CI 证明格式化、挂载、幂等恢复与 fail-closed。VM/可信资源 CMDB 已完成；PROD native-standby caller 已集成；前三轮待机失败，临时访问均已清理；第三轮权限修复后仍重启，Playbooks #599 隔离凭据变量并保护空目录恢复；第四轮 37526370757 全部成功，独立盘/PG17/空业务库/暂停写者/访问撤销已验收，当前 UAT-only DB operation 限制保留 |
| 最新 schema 与容器构件 | Accounts [#194](https://github.com/ai-workspace-services/accounts/pull/194) 提供 52 表最新原生 SQL 与 migratectl init；固定 hash/空库守卫/事务锁/超时、默认预演、零业务行与干净版本回执。本地与最终 PostgreSQL 17 CI 已通过，已合并为 `ddee4b01778fd1d1d644a1bc936624c81ec76093`；合并后的 [CI 37500884987](https://github.com/ai-workspace-services/accounts/actions/runs/37500884987) 已成功发布 full-SHA 镜像，Playbooks #597 owner 已合并；调用方 #1333 已合并并接受实际待机，独立审核及真实初始化仍待完成。Billing #44 cloud_vendor_costs SQL/main CI 资格已完成，Playbooks #600 受限增量 owner 已合并并通过真实 PG17；生产 caller/实际执行尚待集成；非空库禁止重建 |
| migratectl + 全业务复制 | migratectl 当前为 Users/Identities/Sessions；订阅、额度、账本与其他业务表的完整 owner 尚待集成 |
| GTM / CNAME | Edge #28/#29、IaC #398/#400、Toolkit #1326 已合并；Serverless DNS caller 使用固定 IaC reusable workflow，PROD gateway 改走受保护的 Edge 入口。GitOps #392 激活仍待 Vault 合同及真实 UAT/生产入口证据 |
| 写者保护 | 目标 Accounts/Billing 与 Doco-CD 必须在初始化、复制和一致性验证期间暂停；Accounts 现有 root/sandbox/review bootstrap、Proxy rotator、默认目录/overlay 写入及 Billing 后台写入尚待运行保护，不能只依靠网关无流量 |
| 主库切换 | 来源只读基线已完成；目标全业务一致性、最终追平与可信切换回执尚未完成，生产维持 Serverless |
| UAT → PROD Full 晋级 | UAT 两跳同步、升级/回退/再次升级与业务资格单独验收；新 PROD 空库不构成 Full 升级资格 |

详细架构与免费额度见知识白皮书 7.2.1–7.2.2，八项主线任务见 12.3；文档 [knowledge #106](https://github.com/ai-workspace-services/knowledge/pull/106) 已合并。

## 本次 owner/caller 改造与验收顺序

- IaC [#399](https://github.com/ai-workspace-infra/iac_modules/pull/399)：一次性 bootstrap API 声明与 VM 依赖；本地 15 项 GCP 契约和 Terraform validate 通过，不代表 live IAM 已应用。
- IaC [#398](https://github.com/ai-workspace-infra/iac_modules/pull/398)、[#400](https://github.com/ai-workspace-infra/iac_modules/pull/400) 已合并 provider 与精确 GitOps SHA、caller/environment 校验、reusable workflow 和稳定 API 别名保护；21 项 provider/请求检查以及迁移后的 legacy/GTM DNS 行为测试通过。
- Edge [#28](https://github.com/ai-workspace-services/edge-gateway/pull/28)、[#29](https://github.com/ai-workspace-services/edge-gateway/pull/29) 已合并 Accounts/Billing 共同模式、完整数据切换门槛和同 run/commit/计划的限时部署授权。旧 PROD controller 不能绕过该入口。
- GitOps [#392](https://github.com/ai-workspace-infra/gitops/pull/392)：Accounts/Billing 的模式限定 CNAME 声明，caller/owner 迁移验证后才能激活。

本分支只做控制面：Serverless preflight 固定 GitOps SHA，所有后续 lane 使用同一 SHA；Cloudflare 变更交给 `iac_modules/.github/workflows/cloudflare-serverless-domains.yml@a7ac40fb0c3e620bdec89edd72b172afefc1f2ee`。稳定 GTM API 别名由 Edge 的 guarded caller 单独调用 IaC action；Serverless publisher 不得重绑它们。品牌主页、控制台、CORS 与静态资源的 HTTP 检查保留。所有 PROD legacy Edge 部署均跳过；UAT 旧发布入口保持现状。

冻结的旧 DNS executor 暂时保留，仅供现有回归检查；真实 UAT owner → caller 验证后再删除。激活新 GitOps 之前须停止或等待使用旧 owner/Edge source 的既有 run 结束，避免旧调用方覆盖入口。新 reusable workflow 的 Vault job/workflow claims 和环境保护须实际核对；PR/local CI 不证明授权可用。

SIT/UAT/PROD 现有 Vault role 源码已增加上述唯一固定 IaC workflow SHA；repository、既有 ref 限制和 token policy 未扩大。合并后按既有 Vault role apply 流程同步，再做真实 owner/caller 验证。源码 allowlist 不代表 live Vault 已应用，PROD 仍只允许版本 tag/release 分支。

合并顺序为 IaC owner → Toolkit caller 与 Edge guarded 发布入口 → GitOps 声明激活。实际主库切换继续等待完整业务一致性和单写者回执，身份复制、路由 plan 或 DNS 收敛均不能替代它。

## 第四轮真实待机验收（2026-10-07）

[37526370757](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37526370757)（`v2026.10.07-r4` / `2b239ba604483e172c68407fcf3dea5a48e30854`）全部成功。固定 Playbooks `c6a4cb6c54c7e6dd2d63c43767f44a228385312a` 对同一 ownership marker、相同镜像且无任何数据库文件的容器完成缺失密码修复；PostgreSQL 17、独立持久盘、空业务库与暂停应用/CD 写者通过，IaC 临时密钥/防火墙撤销和原始 CMDB 保留成功。

成功 artifact `prod-native-standby-receipt` ID `11442304366`，ZIP digest `sha256:fe5afc9f409d35fcf095f5648938f5c1f5c355968de8341cf029045179012714`，原始 receipt SHA-256 `d4bee2cf17648099732a14506b8572d0da9feb83d0db8e0507596d7306d0b9ce` 已实际下载并核对。初始化配置已绑定该 run/attempt/tag/SHA/artifact/hash，`standby_accepted=true`；这不表示 schema 或数据已经写入。独立生产审核仍待配置，初始化调用方在取 Vault/打开访问之前检查本轮真实独立审批，不能使用自己的审核绕过。主库保持 Serverless。

## 原生增量工具与 Billing 受限 owner 资格

Billing #44 SQL 与 Playbooks [#600](https://github.com/ai-workspace-infra/playbooks/pull/600) 的 owner 已合并；[37529510281](https://github.com/ai-workspace-infra/playbooks/actions/runs/37529510281) 全部成功，实际 disposable PostgreSQL 17 完成 52 表原生初始化加第 53 表增量、重复执行及错误摘要拒绝。首轮 37527995099 发现旧工具要求当前版本的历史 SQL；Accounts [#195](https://github.com/ai-workspace-services/accounts/pull/195) 修复 bounded source，仅有已应用 checkpoint 的无 SQL 元数据和下一份准确 hash 的 SQL，不提供 down 或重放旧 schema。

Accounts 合并 source `ac3239a6ddb89fd49c2b15416bf5f6ea588c6797` 的 [main CI 37529455394](https://github.com/ai-workspace-services/accounts/actions/runs/37529455394) 已成功构建发布 `ghcr.io/ai-workspace-services/accounts:sha-ac3239a6ddb89fd49c2b15416bf5f6ea588c6797`，digest `sha256:8a8d92fc2d7cc8a8855400970bb971436fc117bd39366595f55f7e1283a1e961`；native SQL hash/52 表/版本 `2026100601` 不变，当前初始化配置绑定这份预构建镜像及 Playbooks `96065b03b2e0e3d329f6f9a5ed7aff5fe521dbd2`。真实生产还需 registry pull/compiled manifest/目标守卫回执；资格检查不是生产执行。Billing 生产 caller 与实际初始化/增量/全业务复制/切换继续按门槛执行，生产 schema 写入仍待已请求的独立审核配置。
