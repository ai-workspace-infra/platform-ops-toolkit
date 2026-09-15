# GCP OIDC Bootstrap 操作指南

本文说明如何准备 `gcp-oidc-bootstrap` 所需的最小 GCP Auth 信息，并通过 Vault
KV v2 保存后执行 Terraform bootstrap 验证。路径按环境和 GCP 账号标识隔离，避免
同一环境下多个 GCP 账号互相覆盖。

## 1. 获取 GCP Project ID

项目 ID 已确定：

```yaml
UAT:  xworktech-open-platform-uat
PROD: xworktech-open-platform-prod
```

## 2. 获取短期 `GCP_ACCESS_TOKEN`

推荐使用 GCP ADC 生成短期 OAuth access token：

```bash
gcloud auth application-default login
gcloud auth application-default print-access-token
```

如使用专用 bootstrap Service Account，可使用 impersonation：

```bash
gcloud auth application-default print-access-token \
  --impersonate-service-account=<bootstrap-service-account-email>
```

该 GCP principal 必须具备创建 Workload Identity Pool/Provider、创建 Service Account、
修改项目和 Service Account IAM policy、启用所需 API 的权限。不得生成或保存长期
Service Account JSON private key。

## 3. 写入 Vault KV v2

先使用具备写权限的 Vault 管理员会话：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='<管理员token>'
```

不要把 `VAULT_TOKEN` 或 `GCP_ACCESS_TOKEN` 提交到 Git 或发送到聊天中。

账号标识使用 GitOps 声明中的 `spec.gcp_account_id`。当前账号为 `xworktech`，因此
UAT/PROD 的输入路径分别为：

```text
kv/CICD/uat/gcp-bootstrap/xworktech
kv/CICD/prod/gcp-bootstrap/xworktech
```

### Shell 脚本写入

使用仓库脚本统一校验环境、账号标识和项目 ID，并通过 KV v2 HTTP API 写入。脚本会
优先使用 `GCP_ACCESS_TOKEN`；未设置时自动调用 ADC 获取短期 token：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='<管理员token>'

GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xworktech-open-platform-uat \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh

GCP_ENVIRONMENT=prod \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xworktech-open-platform-prod \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

如果 token 已由外部受控流程生成，可显式传入，不会写入脚本参数或 Git：

```bash
GCP_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)" \
GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xworktech-open-platform-uat \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

KV v2 的 CLI 逻辑路径是 `kv/CICD/...`；HTTP API 和 Vault policy 路径包含 `/data/`。
详见 [Vault KV v2 官方文档](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)。

## 4. 不暴露 secret 的验证

只验证字段和项目 ID，不打印 access token：

```bash
GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xworktech-open-platform-uat \
GCP_BOOTSTRAP_ACTION=check \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh

GCP_ENVIRONMENT=prod \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xworktech-open-platform-prod \
GCP_BOOTSTRAP_ACTION=check \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

## 5. 验证 Terraform bootstrap

在 GitHub Actions 中运行：

```text
Workflow:   GCP OIDC Bootstrap
environment: uat
action:      plan
```

确认 plan 正常且没有实际变更后，再运行：

```text
environment: uat
action:      apply
```

验证 UAT 成功后，对 PROD 重复执行。PROD 必须经过受保护 GitHub Environment 审批。
workflow 会验证目标项目、创建的 WIF provider、deploy Service Account，并确认 UAT
身份无法访问 PROD 项目。

`GCP_ACCESS_TOKEN` 只是 bootstrap 输入，不是长期凭据。apply 完成后应删除或立即轮换
KV 中对应账号路径的 token；Terraform state、GitOps YAML 和文档中都不得出现 token 或
private key。新增 GCP 账号时，新增对应的 `gcp_account_id`、KV 路径、Vault role/policy
和 Terraform state 前缀，不能复用已有账号路径。
