# GCP OIDC Bootstrap 操作指南

本文说明如何准备 `gcp-oidc-bootstrap` 所需的最小 GCP Auth 信息，并通过 Vault
KV v2 保存后执行 Terraform bootstrap 验证。

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

### UAT

```bash
export GCP_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"

jq -n \
  --arg token "$GCP_ACCESS_TOKEN" \
  --arg project "xworktech-open-platform-uat" \
  '{data:{GCP_ACCESS_TOKEN:$token,GCP_PROJECT_ID:$project}}' |
curl --fail --silent --show-error \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --header "Content-Type: application/json" \
  --request POST \
  --data-binary @- \
  "${VAULT_ADDR}/v1/kv/data/CICD/uat/gcp-bootstrap"
```

### PROD

PROD 使用刷新后的 token，并写入独立路径：

```bash
export GCP_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"

jq -n \
  --arg token "$GCP_ACCESS_TOKEN" \
  --arg project "xworktech-open-platform-prod" \
  '{data:{GCP_ACCESS_TOKEN:$token,GCP_PROJECT_ID:$project}}' |
curl --fail --silent --show-error \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  --header "Content-Type: application/json" \
  --request POST \
  --data-binary @- \
  "${VAULT_ADDR}/v1/kv/data/CICD/prod/gcp-bootstrap"
```

也可以使用 Vault CLI：

```bash
vault kv put -mount=kv CICD/uat/gcp-bootstrap \
  GCP_ACCESS_TOKEN="$GCP_ACCESS_TOKEN" \
  GCP_PROJECT_ID=xworktech-open-platform-uat
```

PROD 将路径和项目 ID 替换为 `CICD/prod/gcp-bootstrap` 与
`xworktech-open-platform-prod`。

KV v2 的 CLI 逻辑路径是 `kv/CICD/...`；HTTP API 和 Vault policy 路径包含 `/data/`。
详见 [Vault KV v2 官方文档](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)。

## 4. 不暴露 secret 的验证

只验证字段和项目 ID，不打印 access token：

```bash
vault kv get -mount=kv -format=json CICD/uat/gcp-bootstrap |
  jq -e '.data.data | has("GCP_ACCESS_TOKEN") and .GCP_PROJECT_ID == "xworktech-open-platform-uat"' \
  >/dev/null && echo "UAT bootstrap KV: OK"

vault kv get -mount=kv -format=json CICD/prod/gcp-bootstrap |
  jq -e '.data.data | has("GCP_ACCESS_TOKEN") and .GCP_PROJECT_ID == "xworktech-open-platform-prod"' \
  >/dev/null && echo "PROD bootstrap KV: OK"
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
KV 中的 token；Terraform state、GitOps YAML 和文档中都不得出现 token 或 private key。
