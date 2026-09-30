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

| KV v2 API path | 字段 |
| --- | --- |
| `kv/data/shared/platform/oidc/open-platform-shared` | 已有 GCP WIF identity 四字段 |
| `kv/data/shared/iam` | `masterkey`、`zitadel-admin@zitadel.iam.svc.plus` |
| `kv/data/shared/databases` | `postgres_root_password`、`zitadel_pg_password` |

`masterkey` 必须是持久保存的非占位 32 字符密钥，重部署保持同一密钥。
管理员密码必须满足现有 role 的复杂度要求。凭据由 Vault action 注入并屏蔽；
临时 Ansible extra-vars 文件权限为 0600，任务结束删除，不上传凭据或 inventory。

IAM DNS 必须先指向 GitOps 对应 VM 公网地址；否则停止部署，避免 Caddy ACME
请求落到旧节点。VM 必须 RUNNING，并启用 OS Login。GCP service account
需要已有 Shared service 方式的实例读取、OS Admin Login 和临时 firewall 权限。

业务入口使用 `playbooks/deploy_iam_domain.yml`，先准备本机 PostgreSQL 与 ZITADEL
专用数据库/用户，再调用用户指定的 `playbooks/deploy_zitadel_docker.yaml`。
不执行其他业务库初始化。容器镜像仍由所选 Playbooks 版本的 Compose 模板决定，
该模板目前含 `latest`；此 workflow 不承诺镜像 digest 固定或数据迁移能力。

部署成功必须通过 TLS OIDC discovery 验证。代码验证通过不代表远端部署已完成。
