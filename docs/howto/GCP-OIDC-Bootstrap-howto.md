# GCP OIDC Bootstrap 操作指南

本文说明如何准备 `gcp-oidc-bootstrap` 所需的最小 GCP Auth 信息，并通过 Vault
KV v2 保存后执行 Terraform bootstrap 验证。路径按环境和 GCP 账号标识隔离，避免
同一环境下多个 GCP 账号互相覆盖。

## 0. Bootstrap 前置检查

先确认本机同时具备 Vault 写入会话和 GCP ADC。检查命令不会打印任何 secret：

```bash
if vault token lookup >/dev/null 2>&1; then
  echo "VAULT_SESSION=available"
else
  echo "VAULT_SESSION=unavailable"
fi

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "GCP_ADC_TOKEN=available"
else
  echo "GCP_ADC_TOKEN=unavailable"
fi
```

如果 Vault 会话不可用，先在本机完成管理员登录；管理员 token 只保留在本地环境：

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login
export VAULT_TOKEN='<管理员token>'
```

如果 GCP ADC 不可用，先执行：

```bash
gcloud auth application-default login
```

不能用空 token 或占位符初始化 KV；否则 Terraform bootstrap 会在读取阶段失败。

## 1. 获取 GCP Project ID

项目 ID 已确定：

```yaml
UAT:  xwork-open-platform-uat
PROD: xwork-open-platform-prod
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

先使用具备写权限的 Vault 管理员会话。脚本支持显式 `VAULT_TOKEN`，也支持直接复用
`vault login` 保存的 CLI 会话；二选一即可：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='<管理员token>'
```

也可以不导出 `VAULT_TOKEN`，改为：

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login
```

此时脚本会使用 Vault CLI 会话读写 KV，不要求把管理员 token 放进环境变量。

不要把 `VAULT_TOKEN` 或 `GCP_ACCESS_TOKEN` 提交到 Git 或发送到聊天中。

账号标识使用 GitOps 声明中的 `spec.gcp_account_id`，支持可读账号名或邮箱样式（例如
`platform@xworktech.com`），但禁止 `/` 等路径分隔符。当前账号为 `xworktech`，因此
UAT/PROD 的输入路径分别为：

```text
kv/CICD/uat/gcp-bootstrap/xworktech
kv/CICD/prod/gcp-bootstrap/xworktech
```

对于非 `xworktech` 账号，初始化脚本必须显式提供该账号对应的
`GCP_EXPECTED_PROJECT_ID`；没有 project 映射时脚本会拒绝写入，避免跨账号或跨环境
误写 Vault 路径。例如：

```bash
GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=platform@xworktech.com \
GCP_PROJECT_ID=xwork-open-platform-uat \
GCP_EXPECTED_PROJECT_ID=xwork-open-platform-uat \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

### Shell 脚本写入

使用仓库脚本统一校验环境、账号标识和项目 ID，并通过 KV v2 HTTP API 写入。脚本会
优先使用 `GCP_ACCESS_TOKEN`；未设置时自动调用 ADC 获取短期 token：

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='<管理员token>'

GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xwork-open-platform-uat \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh

GCP_ENVIRONMENT=prod \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xwork-open-platform-prod \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

如果 token 已由外部受控流程生成，可显式传入，不会写入脚本参数或 Git：

```bash
GCP_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)" \
GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xwork-open-platform-uat \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

KV v2 的 CLI 逻辑路径是 `kv/CICD/...`；HTTP API 和 Vault policy 路径包含 `/data/`。
详见 [Vault KV v2 官方文档](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)。

对应的 PROD HTTP endpoint 为：

```text
${VAULT_ADDR}/v1/kv/data/CICD/prod/gcp-bootstrap/<gcp_account_id>
```

当前账号标识为 `xworktech`，所以实际路径为：

```text
${VAULT_ADDR}/v1/kv/data/CICD/prod/gcp-bootstrap/xworktech
```

## 4. 不暴露 secret 的验证

只验证字段和项目 ID，不打印 access token：

```bash
GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xwork-open-platform-uat \
GCP_BOOTSTRAP_ACTION=check \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh

GCP_ENVIRONMENT=prod \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xwork-open-platform-prod \
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
和 Terraform state 前缀，不能复用已有账号路径。邮箱样式账号会原样保留在 Vault/GCS
隔离路径中，便于人工识别。

## 6. UAT 完整验证流程

以下流程用于确认 bootstrap 完成后，GitHub Actions 能通过 GitHub OIDC 使用新建的 GCP
Workload Identity Federation 身份。所有命令都限定为 UAT；不要把 `environment` 改为
`prod`，也不要在 UAT 验证阶段执行 PROD workflow。

### 6.1 修复 ADC 认证并写入短期 token

如果出现 `Reauthentication required`、`invalid_scope` 或无法刷新 token，重新建立 ADC：

```bash
gcloud auth application-default login
```

然后立即生成短期 token 并写入 UAT 账号路径：

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

GCP_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"
test -n "${GCP_ACCESS_TOKEN}"

vault kv put -mount=kv CICD/uat/gcp-bootstrap/xworktech \
  GCP_ACCESS_TOKEN="${GCP_ACCESS_TOKEN}" \
  GCP_PROJECT_ID=xwork-open-platform-uat

unset GCP_ACCESS_TOKEN
```

也可以使用仓库脚本：

```bash
GCP_ENVIRONMENT=uat \
GCP_ACCOUNT_ID=xworktech \
GCP_PROJECT_ID=xwork-open-platform-uat \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

### 6.2 不暴露 token 地检查 Vault 字段

```bash
vault kv get -mount=kv -format=json CICD/uat/gcp-bootstrap/xworktech |
  jq -e '.data.data |
    (.GCP_ACCESS_TOKEN | type == "string" and length > 0) and
    (.GCP_PROJECT_ID | type == "string" and . == "xwork-open-platform-uat")' >/dev/null &&
  echo "UAT GCP bootstrap secret: OK"
```

只看到 `UAT GCP bootstrap secret: OK` 即表示字段存在；不要把普通 `vault kv get` 的
输出写入终端记录或 CI 日志。

### 6.3 执行 UAT plan

在 GitHub Actions 手工运行：

```text
Workflow:   GCP OIDC Bootstrap
environment: uat
action:      plan
```

成功判据：GitOps 声明校验、Vault JWT 登录、项目 ID 交叉校验、Terraform `init`、
`fmt-check`、`validate` 和 `plan` 全部通过；`apply`、WIF smoke test 和 runtime
output 写入步骤应被跳过。

### 6.4 执行 UAT apply 并验证 OIDC

确认 plan 内容符合预期后，再运行：

```text
Workflow:   GCP OIDC Bootstrap
environment: uat
action:      apply
```

成功判据：

- UAT Workload Identity Pool/Provider 创建或复用成功；
- `github-actions-uat` Service Account 创建或复用成功；
- `google-github-actions/auth@v2` 使用新建身份登录成功；
- `gcloud projects describe xwork-open-platform-uat` 成功；
- UAT 身份访问 `xwork-open-platform-prod` 的负向检查通过；
- provider 和 Service Account 输出写入 `kv/uat/platform/oidc/xworktech`。

查看运行状态和失败日志：

```bash
gh run list --repo ai-workspace-infra/platform-ops-toolkit \
  --workflow 'GCP OIDC Bootstrap' --branch main --limit 1

gh run view <RUN_ID> --repo ai-workspace-infra/platform-ops-toolkit --log-failed
```

### 6.5 常见失败处理

| 错误 | 处理 |
| --- | --- |
| `403 Forbidden`（Vault） | 确认 UAT role 已写入，并确认 role 为 `github-actions-platform-ops-toolkit-uat-gcp-bootstrap-xworktech`。 |
| `401 Invalid Credentials`（Terraform/GCP） | Vault 中的 `GCP_ACCESS_TOKEN` 已过期或无效，重新执行 6.1。 |
| `invalid_scope`（gcloud ADC） | 执行 `gcloud auth application-default login`，重新生成 token 并覆盖 KV。 |
| `404`（Vault KV） | CLI 使用 `CICD/uat/gcp-bootstrap/xworktech`；只有 HTTP API 路径包含 `/data/`。 |

如果 UAT apply 在 Terraform 阶段失败，后续 OIDC 登录和 smoke test 尚未发生；先修复
bootstrap token、权限或 API 问题，再重新执行 UAT apply。生产变更必须另行规划，并经过
受保护 GitHub Environment 审批。

### 6.6 Bootstrap principal 的 GCP 最小前置权限

GCP_ACCESS_TOKEN 对应的 principal 必须先在 UAT 项目中具备 bootstrap 权限。当前
Terraform identity module 至少需要以下角色：

    roles/iam.workloadIdentityPoolAdmin
    roles/iam.serviceAccountAdmin
    roles/resourcemanager.projectIamAdmin
    roles/serviceusage.serviceUsageAdmin

bootstrap Service Account 默认只保留身份和 IAM 管理职责，不自动授予
`roles/storage.admin`、`roles/compute.admin` 等业务基础设施权限；这些权限应由后续
runtime deploy Service Account 按资源需求单独授予。权限应授予给生成
GCP_ACCESS_TOKEN 的 principal，不能只授予将要创建的 github-actions-uat 账号。

本次 UAT apply 的实际结果是：

    iam.workloadIdentityPools.create denied
    iam.serviceAccounts.create is required

这表示 Vault token 已成功读取且 OAuth token 已被 GCP 接受，但 bootstrap principal
权限不足；Terraform 没有完成 WIF 创建，后续 GitHub OIDC 登录和资源创建验证不会执行。
补齐权限后，重新运行 6.4，成功后再验证下游 Cloud Run 或其他 UAT 资源。

### 6.7 首次 bootstrap 的手动权限补全

首次运行不能依赖 Terraform 给当前 access token 自己授予权限。请由已有的 UAT 项目
管理员为生成 GCP_ACCESS_TOKEN 的 principal 预先授予以下角色：

    roles/iam.workloadIdentityPoolAdmin
    roles/iam.serviceAccountAdmin
    roles/resourcemanager.projectIamAdmin
    roles/serviceusage.serviceUsageAdmin

例如，先将 GCP_BOOTSTRAP_MEMBER 设置为实际 principal（user: 邮箱或
serviceAccount: 邮箱），再执行：

    export GCP_BOOTSTRAP_MEMBER="user:admin@example.com"
    export GCP_PROJECT_ID=xwork-open-platform-uat

    for role in \
      roles/iam.workloadIdentityPoolAdmin \
      roles/iam.serviceAccountAdmin \
      roles/resourcemanager.projectIamAdmin \
      roles/serviceusage.serviceUsageAdmin; do
      gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
        --member="${GCP_BOOTSTRAP_MEMBER}" \
        --role="${role}"
    done

不要把上述管理员 principal 写入 Vault bootstrap KV；Vault 只保存短期
GCP_ACCESS_TOKEN 和 GCP_PROJECT_ID。权限补全后，再按 6.3 和 6.4 重新执行 UAT plan/apply。

### 6.8 不要用 credentials.json 代替 bootstrap token

不建议把临时最高权限的 `credentials.json` 写入
`CICD/uat/gcp-bootstrap/xworktech` 或其他 KV 路径。该文件通常包含 GCP Service
Account 私钥；Vault KV v2 保存的是版本化静态数据，不会因为 Vault 登录 token 的
TTL 到期而自动删除数据。即使 `GCP_ACCESS_TOKEN` 已过期，KV 中的旧字符串仍可能存在；
Service Account 私钥也不会因为 KV TTL 到期而在 GCP 中自动撤销。

bootstrap KV 只保留以下最小字段：

    GCP_ACCESS_TOKEN=<短期 OAuth access token，建议 TTL 不超过 1 小时>
    GCP_PROJECT_ID=xwork-open-platform-uat

如果必须通过 HTTP API 写入，发送的只是上述字段，不是 JSON 私钥文件：

    {"data":{"GCP_ACCESS_TOKEN":"<short-lived-oauth-token>","GCP_PROJECT_ID":"xwork-open-platform-uat"}}

bootstrap apply 成功后，立即删除或覆盖一次性 token，并保留 Vault 审计记录：

    vault kv patch -mount=kv CICD/uat/gcp-bootstrap/xworktech GCP_ACCESS_TOKEN="REVOKED"

然后由管理员在 GCP 侧确认该 token 已失效；不要把 access token、私钥或完整
`credentials.json` 输出到 shell history、GitHub Actions 日志或 Git 仓库。

正常的 Terraform 和部署流水线应使用 GitHub OIDC -> Workload Identity Federation
-> 环境专属 Service Account，不使用长期 Service Account key。只有在明确的
break-glass 场景下，才允许使用受限、可审计、设置过期时间的临时凭据；完成操作后
必须立即禁用/删除对应凭据，并重新运行 OIDC smoke test。

### 6.9 Bootstrap 后切换到 GCP OIDC JWT Role

Bootstrap apply 成功后，后续 GCP IAC workflow 不再读取
`CICD/<environment>/gcp-bootstrap/<gcp_account_id>` 中的
`GCP_ACCESS_TOKEN`。它们使用以下环境和账号输入读取运行时身份：

    Vault JWT role: github-actions-platform-ops-toolkit-<environment>-gcp-oidc-<gcp_account_id>
    Vault KV path:  <environment>/platform/oidc/<gcp_account_id>

运行时 KV 只包含非密钥身份信息：

    gcp_workload_identity_provider
    gcp_oidc_audience
    deploy_service_account
    project_id

认证链路为：

    GitHub Actions OIDC JWT
      -> Vault JWT auth role（20 分钟 batch token，只读运行时路径）
      -> Google STS/WIF
      -> 环境专属 deploy Service Account

这与 AWS `AssumeRoleWithWebIdentity` 的职责对应：Vault JWT role 负责短期读取授权，
Google STS/WIF 负责把 GitHub OIDC 身份交换为 GCP 短期凭据。LandingZone、Account 和
Resources workflow 的 `cloud_provider`、`vault_env_path`、`gcp_account_id` 都是输入
参数；只有选择 `gcp-cloud` 时才启用该链路，AWS 路径保持原有配置。

运行时 role 只允许声明的 workflow 和环境 ref：UAT 使用 `main`/`uat-*`，PROD 使用
`release/v*`/`v*`。WIF provider 同时使用 GitOps 的 `subjects` 生成 subject 条件，
禁止其他 repository、环境或分支复用该 Service Account。

### 6.10 通过参数运行 GCP Landing Zone / Resources

完整验证用例见 [`GCP-OIDC-Bootstrap-test-cases.md`](GCP-OIDC-Bootstrap-test-cases.md)。

GCP 不使用 AWS 的 `component/<name>` 目录约定。GCP 平台 IAC 的唯一入口是：

    iac_modules/terraform-hcl-standard/gcp-cloud/envs/<environment>

GitOps manifest 负责声明项目、网络、Artifact Registry、Cloud Run 和 Vault 节点；
workflow 负责渲染 manifest、注入运行时 WIF 身份，并使用组织统一的 S3-compatible
Terraform state。多云 master 根据 `cloud_provider` 路由，选择 GCP 时不会调用
AWS 的 LandingZone/Resources matrix。

可手动运行：

    gh workflow run gcp-iac-pipeline.yml \
      --ref main \
      -f deploy_action=plan \
      -f vault_env_path=uat \
      -f gcp_account_id=xworktech \
      -f gitops_repo_name=https://github.com/ai-workspace-infra/gitops.git \
      -f gitops_repo_ref=main

如需使用其他 GCP 账号或资源清单，只改变输入参数；不要修改 workflow 中的项目、
Service Account、WIF provider 或 state key。`gcp_resource_manifest` 必须位于
`resources/<namespace>/<environment>/gcp/`，并且清单中的 `global.environment`、
`project_id` 和 organization ID 会在 Terraform 之前校验。

执行顺序：

    gcp-oidc-bootstrap.yml (apply)
      -> gcp-iac-pipeline.yml (plan)
      -> gcp-iac-pipeline.yml (apply, UAT)
      -> gcp-iac-pipeline.yml (apply, PROD, protected environment approval)

GCP 运行时 workflow 只从 Vault JWT role 读取非密钥 OIDC 输出和统一 state 配置，
不会读取 bootstrap access token，也不会生成 `credentials.json`。state key 按
`environment/account/cloud workspace` 隔离，例如：

    platform-ops-toolkit/uat/xworktech/gcp-platform/terraform.tfstate
    platform-ops-toolkit/prod/xworktech/gcp-platform/terraform.tfstate
