# GCP Terraform bootstrap 的 Vault KV 规划

本文记录 `gcp-oidc-bootstrap.yml` 所需的最小 GCP Auth 合约。Vault 使用 KV v2
mount `kv`；因此 CLI 使用逻辑路径时省略 `data/`，HTTP API 和 policy 使用完整的
`kv/data/` 路径。

## Bootstrap 输入

每个环境和 GCP 账号使用独立路径；`<gcp_account_id>` 是 GitOps 声明中的稳定小写账号标识：

```text
kv/CICD/uat/gcp-bootstrap/<gcp_account_id>
kv/CICD/prod/gcp-bootstrap/<gcp_account_id>
```

对应的 HTTP/API 路径为：

```text
kv/data/CICD/uat/gcp-bootstrap/<gcp_account_id>
kv/data/CICD/prod/gcp-bootstrap/<gcp_account_id>
```

最小字段如下：

| 字段 | 是否敏感 | 用途 | 生命周期 |
| --- | --- | --- | --- |
| `GCP_ACCESS_TOKEN` | 是 | Terraform provider 的短期 OAuth access token | 仅在 bootstrap workflow 运行期间有效，TTL 不超过 1 小时；Vault JWT role 默认 20 分钟 |
| `GCP_PROJECT_ID` | 否 | 与 GitOps 声明交叉校验，防止 token 指向错误项目 | 可长期保存，但必须与环境固定映射一致 |

`GCP_ACCESS_TOKEN` 对应的 GCP principal 必须只具备 bootstrap 所需的最小权限，至少
包括：读取目标项目、启用所需 API、创建/管理 Service Account、创建/管理 Workload
Identity Pool/Provider，以及更新目标项目和 Service Account IAM policy。权限授予在
GCP IAM 中完成，不把 role 列表或 token 写入 Git。

bootstrap workflow 不需要、也禁止读取以下字段：

```text
credentials.json
private_key
client_secret
refresh_token
GOOGLE_APPLICATION_CREDENTIALS
```

因此不生成或保存长期 GCP Service Account JSON key。token 缺失、过期或项目 ID 不匹配
时 workflow 必须失败，不能回退到本地 ADC 或长期密钥。

## Bootstrap 输出

apply 成功后，workflow 使用 Vault bootstrap role 将非密钥运行时身份写入环境专属路径：

```text
kv/uat/platform/oidc/<gcp_account_id>
kv/prod/platform/oidc/<gcp_account_id>
```

字段合约：

| 字段 | 来源 | 用途 |
| --- | --- | --- |
| `gcp_workload_identity_provider` | Terraform output `workload_identity_provider` | `google-github-actions/auth` 的 provider resource name |
| `deploy_service_account` | Terraform output `service_account_email` | GitHub Actions 使用的环境专属 deploy Service Account |
| `project_id` | GitOps 声明 | 运行时项目选择与审计 |

这些值不是凭据，但仍按环境隔离，禁止写入 `kv/shared`。workflow 不能把 Vault response
或 token 打印到日志。

## Policy 与 Role 边界

对应 Vault policy/role：

```text
github-actions-platform-ops-toolkit-uat-gcp-bootstrap-<gcp_account_id>
github-actions-platform-ops-toolkit-prod-gcp-bootstrap-<gcp_account_id>
```

UAT role 只能：

- 读取 `kv/data/CICD/uat/gcp-bootstrap/<gcp_account_id>`；
- 读取并更新 `kv/data/uat/platform/oidc/<gcp_account_id>`。

PROD role 只能：

- 读取 `kv/data/CICD/prod/gcp-bootstrap/<gcp_account_id>`；
- 读取并更新 `kv/data/prod/platform/oidc/<gcp_account_id>`。

两个 role 都绑定到：

```text
repository = ai-workspace-infra/platform-ops-toolkit
job_workflow_ref = .../.github/workflows/gcp-oidc-bootstrap.yml@*
ref = refs/heads/main
environment = <uat|prod>
```

PROD GitHub Environment 必须启用审批保护。UAT role 不得读取 PROD 路径，PROD role 不得
读取 UAT 路径。

## 写入与轮换流程

```text
Vault JWT login
  -> read kv/CICD/<env>/gcp-bootstrap/<gcp_account_id>
  -> Terraform plan/apply with short-lived GCP_ACCESS_TOKEN
  -> read Terraform outputs
  -> write kv/<env>/platform/oidc/<gcp_account_id>
```

`GCP_ACCESS_TOKEN` 由外部受控的短期 token 签发流程提供；本 workflow 不负责创建长期
密钥。token 轮换只需更新 bootstrap 输入路径，不需要修改 GitOps 声明或 Terraform
state。provider resource name 和 deploy Service Account 变更时，必须重新执行 workflow
并同步检查对应环境的下游 Vault policy 和 GitHub Environment。
