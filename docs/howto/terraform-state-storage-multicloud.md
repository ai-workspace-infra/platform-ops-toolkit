# 多云 Terraform IAC State 存储规范

GCP、AWS、Azure 的 bootstrap 和后续 IAC workflow 统一使用一个组织级
S3-compatible Terraform state 服务。Terraform backend 不按云厂商切换：云厂商只
影响 provider 和资源，state 存储保持一致。

GCP、AWS、Azure bootstrap role 都是长期保留的云控制面身份。它们负责各自云的
bootstrap 和后续 Landing Zone 权限，不负责创建或删除 state 服务。state 服务只配置
一套，连接信息按环境从 Vault `CICD/<env>/iac_state` 记录读取。

## Vault 合约

Vault 使用 KV v2 mount `kv`，state 连接信息按环境存放：

```text
CLI:  vault kv get -mount=kv CICD/<env>/iac_state
API:  /v1/kv/data/CICD/<env>/iac_state
```

最小字段：

```text
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
TF_STATE_REGION
```

`TF_STATE_SECRET_KEY` 和 `TF_STATE_ACCESS_KEY` 只能通过 Vault 注入 workflow，不能写入
Git、GitHub Variables 或 Terraform 配置文件。

## State key 规范

所有 state object key 使用以下格式：

```text
terraform/<environment>/<project>/<cloud>/<account>/<workspace>/terraform.tfstate
```

示例：

```text
terraform/uat/xworktech/gcp-cloud/xworktech/gcp-oidc-bootstrap/terraform.tfstate
terraform/prod/platform-ops-toolkit/aws-cloud/primary/bootstrap-identity/terraform.tfstate
terraform/uat/platform-ops-toolkit/azure-cloud/primary/bootstrap-identity/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/primary/ai-workspace/terraform.tfstate
```

其中：

- `environment`：`dev`、`sit`、`uat`、`prod`；
- `project`：GitOps 项目或基础域名；
- `cloud`：固定 provider ID，例如 `gcp-cloud`、`aws-cloud`、`akamai-cloud`；
- `account`：云账号、项目或订阅的稳定可读标识；
- `workspace`：具体 Terraform 管理边界，不使用共享 workspace。

Bootstrap role 的保留规则：

- `github-actions-platform-ops-toolkit-uat-gcp-bootstrap-*`、`-prod-gcp-bootstrap-*`
  不删除；
- `github-actions-platform-ops-toolkit-prod-aws-bootstrap` 不删除；
- Azure bootstrap role 接入后同样不删除；
- 角色权限可以更新，旧 role 只有在完成替代、迁移和审计后才能由独立清理变更删除；
- `create_vault_service_repo_roles.sh` 只清理明确列入 deprecated allowlist 的旧 role。

同一 environment、project、cloud、account、workspace 只能有一个 canonical key。迁移旧 state
时必须先登记旧 key 和新 key，不能直接覆盖未知对象。

## Workflow 约定

每个 workflow 按相同顺序执行：

```text
Vault JWT login
  -> read kv/data/CICD/<env>/iac_state
  -> validate all TF_STATE_* fields
  -> terraform init with S3 backend
  -> terraform plan/apply
```

S3 backend 的标准参数为：

```text
endpoint
bucket
key
access_key
secret_key
region
skip_credentials_validation=true
skip_metadata_api_check=true
skip_region_validation=true
use_path_style=true
use_lockfile=true
```

GCP bootstrap 的短期 `GCP_ACCESS_TOKEN` 只用于 GCP provider；AWS/Azure bootstrap 的
云凭据也只用于对应 provider；它们都不能替代 state backend
的 S3-compatible credentials。反过来，`TF_STATE_*` 也不能用于 GCP provider。

## 隔离与权限

Vault role 按环境限制读取范围；state 服务侧同时按 bucket/prefix 授权。建议至少保证：

- UAT role 不能读取或写入 PROD prefix；
- 不同 GCP account 使用不同 account segment；
- bootstrap、landingzone、resource matrix 使用不同 workspace segment；
- PROD apply 仍需受保护 GitHub Environment 审批；
- state bucket 启用版本控制和锁定能力；
- workflow 结束后不保留 backend credentials 临时文件。

## 当前 GCP bootstrap

GCP OIDC bootstrap 使用 GitOps 声明中的环境/账号 state key，但 bucket 和连接信息统一从
`kv/data/CICD/<env>/iac_state` 读取。对应 workflow 不再使用 `backend "gcs"`。

## External providers

`ucloud`、`ulighthost` 等没有 Terraform provider 的平台不创建 `tfstate`。它们只在
同一个 bucket 写入以下对象：

```text
inventory/<environment>/<project>/<cloud>/<account>/<workspace>.json
runs/<environment>/<project>/<cloud>/<account>/<workspace>/<run-id>.json
```

GitOps 声明必须含有 `management_mode: existing`、`provisioner: ansible` 与
`lifecycle: external`；external adapter 不允许运行 Terraform 或创建、销毁资源。
