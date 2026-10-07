# Toolkit 脚本清理与 owner 交接记录

本批次覆盖用户列出的 48 个文件：14 个测试/fixture、21 个 XConnect lab 文件、13 个 serverless 文件。按实际副作用归属，采用 **owner 实现 → Toolkit 固定 SHA caller → contract/UAT 验证 → 删除旧副本**。六云 provider、master 八个 jobs、stages 三个 jobs、独立正向与销毁 DAG 保持设计 v0.6。

## 测试目录

12 个控制面测试和 `fixtures/uat-upgrade-acceptance.jq` 移至 `scripts/tests/control_plane/`，更新全部活动调用，并由 `control-plane-contracts.yml` 在 PR/push 上运行。它们验证输入、目标选择、固定 SHA、receipt、环境和放行条件，归 Toolkit。

| 文件 | 归属与处理 |
| --- | --- |
| `daily_snapshot_tag_routing_test.sh`、`workflow_dispatch_input_limit_test.sh` | Toolkit；移至统一控制面测试目录 |
| `environment_upgrade_test.py`、`environment_data_operations_test.py`、`import_receipt_test.py`、`fixtures/uat-upgrade-acceptance.jq` | Toolkit；保留数据操作选择和证据校验，移目录 |
| `hybrid_uat_matrix_contract_test.sh` | Toolkit；以当前固定 owner、master 和 receipt 链替换已不存在的 inline Terraform step 断言；保留禁止 caller 自行 import 的约束 |
| `xconnect_cloud_lab_vault_role_contract_test.sh`、`xconnect_ai_aggregator_matrix_contract_test.sh`、`xconnect_formal_uat_lab_contract_test.sh`、`xconnect_gateway_dns_contract_test.sh`、`xconnect_playbooks_observation_caller_contract_test.sh`、`xconnect_declared_network_contract_test.sh` | Toolkit；验证当前 caller、精确 claims 和 owner 路由，移目录 |
| `xconnect_xhttp_runtime_contract_test.sh` | 仍保留原位；Playbooks 已补真实 verifier 测试，旧 helper/caller 尚未完成运行验证，不提前删除 |

## XConnect lab

下表旧路径均以 `.github/scripts/xconnect-lab/` 为前缀。存在 owner 不表示所有旧入口已停用；混合 executor 保持冻结，不能原样搬入 actions。

| 文件 | owner 与接入状态 | 删除条件 |
| --- | --- | --- |
| `prepare.py`、`terraform-diagnostics.py`、`lease.sh`、`test_prepare.py`、`test_terraform_diagnostics.py` | IaC `scripts/pipeline/xconnect-lab-*`；lifecycle action 已接入，补固定版本/敏感日志/失败退出码测试 | 新固定版本的 exact-run preflight 与 lifecycle 证据；旧混合入口不再读取 |
| `probe-control-plane.py`、`test_probe_control_plane.py` | Playbooks service-probes；匿名 control-plane probe caller 固定 owner | 精确 caller/owner SHA 的只读 rehearsal；不将匿名响应当作登录或业务验收 |
| `node-observation.sh`、`remote-client-observation.sh`、`remote-gateway-observation.sh`、`test_observation_remote.py` | Playbooks node-observation / runtime Role；活动 observation caller 固定 owner | 精确节点、可信 host keys、同 run receipt 与观察证据 |
| `gateway.sh` | Playbooks runtime Role；独立 runtime-control 和 Gateway reconcile 改为 owner action，cloud-lab 完整安装链仍有旧 caller | 原安装/配置链切换与真实目标收敛；不能仅依据新增 verifier 删除 |
| `verify-xhttp-runtime.sh` | Playbooks runtime Role 新增 `xhttp_verify`，覆盖 Gateway/One 有效配置 | 正式 lab caller 使用 owner verifier，并取得运行证据 |
| `deploy.sh`、`enroll-node.sh`、`desktop.sh` | 主机执行归 Playbooks；混合凭证、Accounts 与交接先拆契约 | owner/caller 的完整同 run 私网 HTTP、WireGuard/XHTTP 证据 |
| `reconcile-gateway-dns.sh` | DNS 归 IaC；Gateway 服务变更归 Playbooks，须拆分 caller | DNS 与主机两条 owner 路由各自验收 |
| `run.sh`、`test_run_topology.py`、`validate-topology.jq`、`validate-zero.jq` | run.sh 混合多 owner 且冻结；拓扑/证据纯校验归 Toolkit，可分离后保留 | 每个执行分支已切换，旧脚本无调用；拓扑/receipt 负例继续通过 |

## Serverless

下表旧路径均以 `.github/scripts/serverless/` 为前缀。

| 文件 | 归属与处理 |
| --- | --- |
| `run_cloudflare_target.sh`、`sync_smtp_secrets.sh` | IaC serverless-provider-operations；活动 caller 已固定 owner，旧副本冻结待真实 provider 验证 |
| `verify_frontend_boundary_assets.sh` | Playbooks service-probes；frontend-assets/public-chain 活动 caller 固定 owner；旧服务执行副本待只读 rehearsal |
| `verify_summary.sh`、`record_image_digest.sh`、`verify_hybrid_contract.sh`、`validate_dispatch_inputs.sh`、`validate_promotion_manifest.sh`、`validate_portal_runtime_domains.sh`、`select-domain-owner.py`、`verify_cloud_run_digest_facts.sh`、`verify_cloud_run_image_digest.sh`、`install_vault_cli.sh` | Toolkit 的状态/证据/环境选择、配置一致性或运行身份工具；保留控制面，不按目录名移入 IaC。Cloud Run 权威查询归 IaC，digest 最终 gate 归 Toolkit |

## SSH 信任与验收

host keys 按部署云资源的 KV 环境/目标来源选择。独立 UAT runtime-control 在 `kv/data/CICD/uat` 成对读取 `SSH_PRIVATE_DEPLOY_KEY_B64` 与 `SSH_KNOWN_HOSTS_B64`；外部 Gateway 从现有精确目标记录同时读取 host、user、key 与 `known_hosts_b64`。后者现有记录位于 `prod/ulighthost-xconnect`，其 UAT 使用属于已有共享目标边界，不将其改为任意跨环境选择。

两个 known_hosts 字段是新增契约，尚无 live 配置证据；缺失、无精确 target 或 key 无效时在 SSH 前失败。Playbooks 使用 `StrictHostKeyChecking=yes`，禁止 `accept-new`、关闭校验或 keyscan 信任首次连接。

Vault role 源码仅允许两个精确 main workflow 和 UAT environment。源码更新不等于 live role 已应用。当前已完成 owner 测试、离线 caller contracts 和 Ansible syntax-check；PR CI 与只读 rehearsal 证据另记。SSH/XHTTP/WireGuard/私网 HTTP、Accounts 写入和 provider apply/destroy 均不得根据 mock 或 PR 合并标记验收完成。

除纯测试目录迁移外，本批次保留旧执行文件。逐个删除前应记录 Toolkit/IaC/Playbooks/GitOps SHA、run/attempt、精确目标、receipt 与收敛证据，确认旧路径零调用，并保留固定 SHA 回退点。

## 已发布与只读运行证据

IaC [#417](https://github.com/ai-workspace-infra/iac_modules/pull/417)、Playbooks [#623](https://github.com/ai-workspace-infra/playbooks/pull/623)、Toolkit [#1376](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1376) 依次通过远端 CI 并合并 main。

[Run 37641969087 / attempt 1](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37641969087) 在 Toolkit `310ec72e39932982912f65f1cf8ab56951554045` 成功执行 `cloud-lab/dry-run`，固定 IaC `d7e49189a5de9c105a940f1c79abfb3b2b33bbd4`、Playbooks `9d585e147348800b1603c4f7b0d8a6bcf0546007`、GitOps `28430b835c4275eea1921aa7fd98c96dbc2c50ef`。

Vault OIDC 登录、固定 checkout、声明校验、release artifacts、匿名 Accounts/Portal 边界、Terraform fmt/init backend=false/validate 通过。云凭证、DNS、AWS OIDC、prepare/apply、主机安装、邀请、额外节点、reconcile 和 cleanup 均跳过。

Artifact `owner-receipt-service-xconnect-control-plane` ID `11492827205`，digest `sha256:afb692da5748c408e4f4e2a3d9501ca52ad81e88363c3cc3e894c71fdb526867`。下载后验证 owner/run/attempt/UAT/operation/scope/accepted；receipt 文件 checksum `0135cfed3f73a5f67bafcfea0264f3fb8ef3cfe63113740c7a226fce810a6f2b`。这是只读路径证据，SSH/数据面和新 Vault claim/key 字段仍待验证。
