# 独立 Shared ZITADEL 部署

入口：`.github/workflows/zitadel-server.yml`。目标由 GitOps
`resources/svc.plus/shared/gcp/open-platform-shared-iam.yaml` 解析；当前目标是
`open-platform-shared-510113 / iam-shared-0`，服务域名来自 `service_domains`。

| deploy_action | service_stage | 行为 |
| --- | --- | --- |
| plan | none | 独立 IAM Terraform state plan |
| apply | none | 只创建或更新 IAM 基础设施 |
| apply | deploy | 基础设施成功后部署 ZITADEL |
| none | deploy | 已有 VM 上单独部署或升级 ZITADEL |
| none | verify | 只验证公开 OIDC discovery、issuer 和 JWKS 地址 |

参照 Vault/Observability 入口，Shared 服务 job 使用 GitHub `prod` Environment
和 `main` ref；资源身份从声明获取，GCP 身份经 GitHub OIDC → Vault → WIF 加载。
运行时生成临时 OS Login key、runner `/32` SSH 防火墙规则和单主机 inventory，
任务结束后撤销访问。默认操作是 plan，无 destroy、迁移或 DNS 修改入口。

首次部署前，先创建专用 Vault role/policy：

```bash
bash scripts/create_vault_service_repo_roles.sh --apply \
  --role github-actions-platform-ops-toolkit-shared-zitadel
```

使用 CLI 的授权管理员会话。部署任务只读取：

Shared KV 首次初始化使用 Toolkit 的 IAM bootstrap 入口。它只写入以下两个
KV v2 路径，不创建 VM、不执行 Terraform/Ansible、不改 DNS，也不迁移旧服务：

```bash
export VAULT_ADDR='https://vault.svc.plus'
# 使用授权管理员会话：VAULT_TOKEN 或本机 vault login
bash scripts/iam/bootstrap_zitadel_kv.sh --check
bash scripts/iam/bootstrap_zitadel_kv.sh --apply --generate-missing
bash scripts/iam/bootstrap_zitadel_kv.sh --check
```

`--generate-missing` 只为缺失字段生成独立随机值，并保留已有字段；如需显式
轮换，使用同名环境变量配合 `--apply` 覆盖。脚本不会打印任何秘密值。

部署任务读取的契约如下：

| KV v2 API path | 字段 |
| --- | --- |
| `kv/data/shared/platform/oidc/open-platform-shared` | 已有 GCP WIF identity 四字段 |
| `kv/data/shared/iam` | `masterkey`、`zitadel-admin@iam.svc.plus`、`login_session_cookie_secret`（至少 32 字符） |
| `kv/data/shared/databases` | `postgres_root_password`、`zitadel_pg_password` |

`masterkey` 必须是持久保存的非占位 32 字符密钥，重部署保持同一密钥。
管理员密码必须满足现有 role 的复杂度要求。凭据由 Vault action 注入并屏蔽；
临时 Ansible extra-vars 文件权限为 0600，任务结束删除，不上传凭据或 inventory。

IAM DNS 必须先指向 GitOps 对应 VM 公网地址；否则停止部署，避免 Caddy ACME
请求落到旧节点。VM 必须 RUNNING，并启用 OS Login。GCP service account
需要已有 Shared service 方式的实例读取、OS Admin Login 和临时 firewall 权限。

业务入口使用 `playbooks/deploy_iam_domain.yml`，先准备本机 PostgreSQL 与 ZITADEL
专用数据库/用户，再调用用户指定的 `playbooks/deploy_zitadel_docker.yaml`。
不执行其他业务库初始化。此入口固定选择 `zitadel_deployment_mode=doco-cd`；
Ansible 只负责主机秘密、PostgreSQL、Caddy 和独立 Doco-CD 运行时，
应用栈由 GitOps `.doco-cd.zitadel.yaml` → `compose/zitadel/docker-compose.yml` 管理。
解析后的 GitOps SHA 同时传给 IaC 与 Doco-CD；使用 `target: zitadel`，
不会误部署仓库默认 Web SaaS 栈。API、Login 和 Doco-CD 镜像 digest 来自
GitOps `.env.shared`，升级通过审核的 GitOps PR 和显式重跑完成。
这遵循 [Doco-CD 的目标配置轮询契约](https://doco.cd/latest/Poll-Settings/)。

需先合并对应 GitOps 与 Playbooks PR，再部署 Toolkit。旧 Compose 模式仅保留为
明确选择的兼容入口，不与 Doco-CD 同时管理应用。不会自动接管已有旧栈或删除其数据；
若目标机已有旧 IAM 容器，应先单独规划无损接管，不能直接启动两套。
主机配置/密钥写入 root/0600 文件；持久数据库与 `/opt/zitadel` PAT 不被清理。
重部署拒绝无意修改既有 masterkey。初始化使用
[ZITADEL 官方 start-from-init 链路](https://zitadel.com/docs/self-hosting/manage/cli/overview)，
不吞掉初始化失败。

部署成功须确认实际 API/Login 容器使用目标 digest 且 healthy，再通过 TLS OIDC
discovery 验证；Doco-CD 自身 healthy 不算验收。代码验证通过不代表远端部署已完成。
