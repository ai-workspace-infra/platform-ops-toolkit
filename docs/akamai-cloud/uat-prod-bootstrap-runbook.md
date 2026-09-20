# Akamai Cloud/Linode UAT 与 PROD Bootstrap Runbook

本文档是 UAT/PROD 的操作入口。敏感值只从本地环境变量或 Vault 管理会话读取，
不得写入 GitOps、GitHub Actions 参数、文档、Terraform 文件或日志。

## 目标矩阵

| 环境 | Terraform / Akamai Cloud | Existing / Ulighthost |
|---|---|---|
| UAT | JP、US、SG | TW |
| PROD | JP、US、SG | PH |

Akamai Terraform 每个环境 3 台 `g6-standard-1`：

```text
JP  -> jp-tyo-3
US  -> us-lax
SG  -> sg-sin-2
```

台湾和菲律宾只进入 external inventory / Ansible Agent Proxy 矩阵，不执行
Terraform 创建、销毁或 apply。

原有 AWS JP 节点继续保留 `tky-proxy.svc.plus` legacy 入口；它与新的
`jp-xconnect.svc.plus` 不冲突。

## Daily Snapshot / Agent Proxy 路由

`Daily Main Snapshot` 完成应用快照后，按下面的矩阵分别 dispatch
`selfhost-orchestrator.yml`：

| 环境 | 云端 Agent Proxy leg | Existing Agent Proxy leg |
|---|---|---|
| UAT | `akamai-cloud`，JP/US/SG，读取 Akamai state | `ulighthost`，TW |
| PROD | 现有 `aws-cloud` 节点 + `akamai-cloud` JP/US/SG | `ulighthost`，PH |

PROD 的 AWS leg 使用现有 AWS state，`include_external_agent_proxy=false`，因此不会把
PH 再次部署到 AWS leg；Akamai leg 使用 `include_external_agent_proxy=true`，才会继续
部署 GitOps 中声明的 PH existing 节点。AWS SPOT 不属于该默认矩阵，也不会由 Daily
Snapshot 新建。Akamai leg 的 state 只做 `init`、`validate`、`inventory` 和 Ansible
部署，状态对象固定为：

```text
terraform/<env>/svc.plus/akamai-cloud/<account>/xconnect/terraform.tfstate
```

每日快照脚本会等待对应的 selfhost workflow 完成；AWS 与 Akamai 使用不同的 workflow
concurrency group，避免两条 PROD leg 互相取消或覆盖。

## 1. 初始化 UAT/PROD KV 与 OIDC Role

使用具有目标 KV 写权限和 JWT role/policy 管理权限的 Vault 管理会话。不要使用已经
出现在聊天、日志或截图中的旧 Token。

```bash
export VAULT_ADDR='https://vault.svc.plus'
export VAULT_TOKEN='<新的 Vault 管理员 Token>'
export LINODE_TOKEN='<Akamai Cloud/Linode Personal Access Token>'
export AKAMAI_ACCOUNT_UAT='<真实账户名或ID>'
export AKAMAI_ACCOUNT_PROD='<真实账户名或ID>'

export TF_STATE_ENDPOINT='<S3-compatible endpoint>'
export TF_STATE_BUCKET='<state bucket>'
export TF_STATE_ACCESS_KEY='<state access key>'
export TF_STATE_SECRET_KEY='<state secret key>'
export TF_STATE_REGION='<state region>'

bash docs/akamai-cloud/init-vault-kv.sh --apply --env all
bash docs/akamai-cloud/init-vault-kv.sh --check --env all
```

## 2. 修复 PROD Role 缺失

如果 workflow 报错：

```text
role "github-actions-platform-ops-toolkit-prod-akamai-oidc-bootstrap-<account>" could not be found
```

只补 PROD 的 OIDC Role/Policy：

```bash
export VAULT_ADDR='https://vault.svc.plus'
export VAULT_TOKEN='<新的 Vault 管理员 Token>'
export AKAMAI_ACCOUNT_PROD='<真实账户名或ID>'

bash scripts/vault/bootstrap_akamai_oidc_roles.sh --apply --env prod
```

校验 Role 和两个 PROD KV：

```bash
vault read auth/jwt/role/github-actions-platform-ops-toolkit-prod-akamai-oidc-bootstrap-<account>
vault kv get -mount=kv CICD/prod/akamai-cloud/<account>
vault kv get -mount=kv CICD/prod/iac_state
```

provider KV 必须包含 `LINODE_TOKEN`；state KV 必须包含：

```text
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
TF_STATE_REGION
```

## 3. 执行 UAT workflow

先执行 UAT `apply`，声明来自 GitOps `main`：

```bash
gh workflow run akamai-cloud-iac.yml \
  --repo ai-workspace-infra/platform-ops-toolkit --ref main \
  -f deploy_action=apply -f vault_env_path=uat \
  -f project=svc.plus -f account='<真实账户名或ID>' \
  -f workspace=xconnect \
  -f resource_manifest=resources/svc.plus/uat/akamai/xconnect.yaml \
  -f gitops_repo_name=ai-workspace-infra/gitops -f gitops_repo_ref=main -f iac_ref=main
```

成功标准：Linode `/v4/profile` 校验通过，Terraform plan/apply 成功，CMDB 输出包含
`jpn-tky`、`us-ca`、`sg` 三个节点。

## 4. 执行 PROD workflow

确认 PROD Role、PROD provider KV 和 PROD state KV 均存在后，再执行：

```bash
gh workflow run akamai-cloud-iac.yml \
  --repo ai-workspace-infra/platform-ops-toolkit --ref main \
  -f deploy_action=apply -f vault_env_path=prod \
  -f project=svc.plus -f account='<真实账户名或ID>' \
  -f workspace=xconnect \
  -f resource_manifest=resources/svc.plus/prod/akamai/xconnect.yaml \
  -f gitops_repo_name=ai-workspace-infra/gitops -f gitops_repo_ref=main -f iac_ref=main
```

PROD state key 必须是：

```text
terraform/prod/svc.plus/akamai-cloud/<account>/xconnect/terraform.tfstate
```

## 5. 验证与安全检查

- UAT 只能读取 `kv/data/CICD/uat/...`，PROD 只能读取 `kv/data/CICD/prod/...`；
- 每个 Akamai 环境只创建 JP、US、SG 三台；
- TW/PH 由 external inventory / Ansible 管理，不生成 Terraform state；
- state key 使用 environment/project/cloud/account/workspace 五级层次；
- Token、state secret、Vault token 不出现在日志或 artifact；
- 原 AWS JP 的 `tky-proxy.svc.plus` legacy CNAME 仍然存在。

不要对 `ulighthost` 资源执行 Terraform `apply`、`destroy` 或自动创建。
