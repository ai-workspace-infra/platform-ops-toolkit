# GCP OIDC Bootstrap 验证用例

本手册验证完整链路：GitOps 声明 → Vault bootstrap JWT role → 短期 GCP OAuth
token → Terraform 创建 WIF → GitHub Actions JWT + Google STS/WIF → GCP IAC。

所有命令都应在 `platform-ops-toolkit` 根目录执行。命令不会打印 secret；不要把
`GCP_ACCESS_TOKEN`、Vault token 或 state access key 复制到日志、Issue 或聊天。

## 测试前置条件

先确认三个仓库的 `main` 已同步，并准备：

```bash
export GCP_ACCOUNT_ID=xworktech
export GCP_ENVIRONMENT=uat
export GCP_PROJECT_ID=xwork-open-platform-uat
export GITOPS_REPO=ai-workspace-infra/gitops
```

Vault KV v2 最小记录：

```text
kv/CICD/uat/gcp-bootstrap/xworktech
  GCP_ACCESS_TOKEN
  GCP_PROJECT_ID

kv/CICD/uat/iac_state
  TF_STATE_ENDPOINT
  TF_STATE_BUCKET
  TF_STATE_ACCESS_KEY
  TF_STATE_SECRET_KEY
  TF_STATE_REGION
```

bootstrap apply 成功后，运行时身份记录必须存在：

```text
kv/uat/platform/oidc/xworktech
  gcp_workload_identity_provider
  gcp_oidc_audience
  deploy_service_account
  project_id
```

## 用例清单

| ID | 用例 | 验证方式 | 通过标准 |
| --- | --- | --- | --- |
| TC-01 | 静态契约 | 运行 contract test | 输出 `PASS` |
| TC-02 | 输入边界 | 使用非法 environment/action/manifest | 在 Terraform 前失败 |
| TC-03 | Vault 隔离 | 检查 role、policy、KV 路径 | UAT 不能读 PROD，反之亦然 |
| TC-04 | bootstrap plan | workflow `action=plan` | 只执行 preflight/plan，不执行 apply |
| TC-05 | bootstrap 权限预检 | 缺少 GCP IAM 权限时执行 plan | 明确列出缺失权限，不修改 GCP |
| TC-06 | bootstrap apply | UAT `action=apply` | 创建 WIF/SA，并写入 runtime KV |
| TC-07 | GCP runtime OIDC | GCP IAC `deploy_action=plan` | 通过 Vault JWT + Google STS，不读取 bootstrap token |
| TC-08 | GCP 资源 apply | UAT `deploy_action=apply` | 使用 WIF SA 创建/更新 UAT 资源 |
| TC-09 | state 隔离 | 检查 init key | environment/project/cloud/account/workspace 均存在 |
| TC-10 | AWS 回归 | 检查 AWS 文件和既有 workflow | AWS bootstrap/IAC 无 diff、原测试不回归 |

## TC-01：静态契约和 Terraform 检查

```bash
bash .github/scripts/tests/gcp_oidc_bootstrap_contract_test.sh
python3 -m unittest scripts/tests/test_iac_state_contract.py

git -C ../oidc-iac-WC diff --name-only origin/main...HEAD \
  | grep -E '^terraform-hcl-standard/aws-cloud/' && exit 1 || true
```

预期：contract test 和 Python tests 通过；本次 iac_modules 变更不包含
`terraform-hcl-standard/aws-cloud/`。

## TC-02：输入和声明边界

正常 UAT 运行：

```bash
gh workflow run gcp-oidc-bootstrap.yml --ref main \
  -f environment=uat -f action=plan
```

正常 GCP IAC 运行：

```bash
gh workflow run gcp-iac-pipeline.yml --ref main \
  -f deploy_action=plan \
  -f vault_env_path=uat \
  -f gcp_account_id=xworktech \
  -f gcp_resource_manifest=resources/xworktech.com/uat/gcp/open-platform-uat.yaml \
  -f gitops_repo_name=https://github.com/ai-workspace-infra/gitops.git \
  -f gitops_repo_ref=main
```

负向检查可使用临时 workflow dispatch：

```bash
gh workflow run gcp-iac-pipeline.yml --ref main \
  -f deploy_action=plan -f vault_env_path=uat \
  -f gcp_account_id=xworktech \
  -f gcp_resource_manifest=resources/xworktech.com/prod/gcp/open-platform-prod.yaml
```

预期：manifest environment 与 `vault_env_path` 不一致时，在 Terraform 前失败；
`gcp_resource_manifest` 不得通过 `..`、绝对路径或非 `resources/<namespace>/<env>/gcp/`
路径绕过校验。

## TC-03：Vault role、policy 和 KV 隔离

```bash
for env in uat prod; do
  role="github-actions-platform-ops-toolkit-${env}-gcp-oidc-xworktech"
  vault read -format=json "auth/jwt/role/${role}" | \
    jq -e --arg role "${role}" \
      '.data.token_type == "batch" and .data.token_ttl == 1200 and \
       (.data.token_policies | index($role) != null)' >/dev/null
  vault policy read "${role}" | grep -Fq "kv/data/${env}/platform/oidc/xworktech"
  vault policy read "${role}" | grep -Fq 'kv/data/CICD'
done
```

不能读取另一环境：

```bash
vault read -format=json auth/jwt/role/github-actions-platform-ops-toolkit-uat-gcp-oidc-xworktech \
  | jq -e '.data.bound_claims.ref | index("refs/tags/v*") == null' >/dev/null
```

## TC-04/TC-05：bootstrap plan 和权限预检

```bash
gh workflow run gcp-oidc-bootstrap.yml --ref main \
  -f environment=uat -f action=plan
run_id="$(gh run list --workflow gcp-oidc-bootstrap.yml --limit 1 --json databaseId \
  --jq '.[0].databaseId')"
gh run watch "${run_id}" --exit-status
```

预期：

- Vault 成功读取 `CICD/uat/gcp-bootstrap/xworktech`；
- `testIamPermissions` 只检查项目资源上的 Service Account、项目 IAM 和
  Service Usage 权限，检查成功后才进入 Terraform；
- Workload Identity Pool/Provider 的 create 权限属于 IAM API 资源操作，不能用
  不存在的 pool 在项目资源上做权威预检，由 Terraform apply 的 IAM API 操作验证；
- plan 阶段不存在 `terraform apply` 执行；
- 项目级权限不足时列出 `iam.serviceAccounts.create`、
  `resourcemanager.projects.setIamPolicy` 等缺失项并失败；
- 权限预检失败时不创建或修改 GCP 资源。

## TC-06：bootstrap apply 和 runtime KV

确认外部管理员已为 bootstrap principal 授予所需权限后：

```bash
gh workflow run gcp-oidc-bootstrap.yml --ref main \
  -f environment=uat -f action=apply
run_id="$(gh run list --workflow gcp-oidc-bootstrap.yml --limit 1 --json databaseId \
  --jq '.[0].databaseId')"
gh run watch "${run_id}" --exit-status

vault kv get -mount=kv -format=json uat/platform/oidc/xworktech | \
  jq -e '.data.data | \
    has("gcp_workload_identity_provider") and \
    has("gcp_oidc_audience") and \
    has("deploy_service_account") and \
    .project_id == "xwork-open-platform-uat"' >/dev/null
echo "UAT runtime OIDC record: OK"
```

预期：Terraform output 的 WIF provider 和 deploy Service Account 与 runtime KV
一致；KV 中不出现 JSON private key。

## TC-07/TC-08：用 runtime OIDC 执行 GCP IAC

先 plan，再 apply：

```bash
gh workflow run gcp-iac-pipeline.yml --ref main \
  -f deploy_action=plan -f vault_env_path=uat \
  -f gcp_account_id=xworktech
plan_run="$(gh run list --workflow gcp-iac-pipeline.yml --limit 1 --json databaseId \
  --jq '.[0].databaseId')"
gh run watch "${plan_run}" --exit-status

gh workflow run gcp-iac-pipeline.yml --ref main \
  -f deploy_action=apply -f vault_env_path=uat \
  -f gcp_account_id=xworktech
apply_run="$(gh run list --workflow gcp-iac-pipeline.yml --limit 1 --json databaseId \
  --jq '.[0].databaseId')"
gh run watch "${apply_run}" --exit-status
```

预期日志包含 Google WIF/STS 认证和目标项目校验；runtime workflow 不读取
`CICD/uat/gcp-bootstrap/xworktech` 的 `GCP_ACCESS_TOKEN`，不生成
`credentials.json`，并能执行：

```text
gcloud projects describe xwork-open-platform-uat
```

## TC-09：Terraform state 隔离

UAT 与 PROD 必须使用不同 canonical key：

```text
platform-ops-toolkit/uat/xworktech/gcp-oidc-bootstrap/terraform.tfstate
platform-ops-toolkit/prod/xworktech/gcp-oidc-bootstrap/terraform.tfstate
terraform/uat/xwork-open-platform-uat/gcp-cloud/xworktech/platform/terraform.tfstate
terraform/prod/xwork-open-platform-prod/gcp-cloud/xworktech/platform/terraform.tfstate
terraform/uat/xwork-open-platform-uat/gcp-cloud/xworktech/spot-validation-uat/terraform.tfstate
```

检查 workflow 使用了 environment/project/cloud/account/workspace 分段，并包含
`use_path_style=true` 与 `use_lockfile=true`。不得使用 GCS backend 或共享 workspace。

## TC-10：PROD 和 AWS 回归

PROD 只允许 release/tag，并必须命中 GitHub protected Environment：

```bash
# Use an approved release/v* branch or v* tag; PROD role rejects main.
: "${PROD_REF:?set PROD_REF to an approved release/v* branch or v* tag}"
gh workflow run gcp-iac-pipeline.yml --ref "${PROD_REF}" \
  -f deploy_action=apply -f vault_env_path=prod \
  -f gcp_account_id=xworktech
```

预期 workflow 在 `prod` Environment 等待审批，未审批前不执行 Terraform apply。

AWS 回归至少执行：

```bash
if git diff --quiet origin/main...HEAD -- \
  .github/workflows/aws-oidc-bootstrap.yml \
  terraform-hcl-standard/aws-cloud; then
  echo "AWS bootstrap/IAC unchanged"
else
  echo "AWS bootstrap/IAC changed unexpectedly" >&2
  exit 1
fi
bash .github/scripts/tests/gcp_oidc_bootstrap_contract_test.sh
```

AWS bootstrap/IAC 不应被 GCP 修改；如需要确认 AWS 实际链路，应使用原有 AWS
OIDC workflow 和其既有 test case，不把 GCP token 或 Vault role 复用到 AWS。

## 2026-09-22 UAT 真实 E2E 证据

- Bootstrap apply：[run 35686936941](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/35686936941) 成功创建 WIF Pool、GitHub provider、`github-actions-uat` Service Account 和 IAM 绑定，并通过新 WIF 身份 smoke test。
- Bootstrap 凭据已当场吊销并销毁 Vault 历史版本；`kv/CICD/uat/gcp-bootstrap/xworktech` 只保留 `GCP_PROJECT_ID=xwork-open-platform-uat`。
- Runtime KV `kv/uat/platform/oidc/xworktech` 只包含 `gcp_workload_identity_provider`、`gcp_oidc_audience`、`deploy_service_account`、`project_id`，不包含 token、JSON key 或 private key。
- Runtime Spot apply：[run 35690778118](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/35690778118) 全程使用 GitHub OIDC → Vault JWT role → Google WIF；实例 `oidc-spot-validation-uat` 在 `asia-east1-a` 创建成功并验证为 `SPOT`。
- Spot 模块设置 `max_run_duration=3600`、`instance_termination_action=DELETE`，验证实例最多运行一小时；独立 state workspace 为 `spot-validation-uat`。

本次真实执行暴露并修复了三个此前静态测试未发现的问题：

1. Bootstrap 未启用 `cloudresourcemanager.googleapis.com`，导致新 WIF 身份无法执行项目 smoke test（iac_modules #326）。
2. Vault runtime role 将实际的 `gcp-iac-pipeline.yml` 错写为 `.yaml`，导致 JWT `job_workflow_ref` 被拒绝（platform-ops-toolkit #892）。
3. Spot 模块同时使用 `provisioning_model=SPOT` 和 `preemptible=false`；现已改为一致的 Spot 调度并增加一小时原生生命周期（iac_modules #327、platform-ops-toolkit #893）。

## 失败处理

- Vault 404：检查 KV v2 mount、`CICD/<env>/...` 路径和 policy 的 `/data/` 路径。
- GCP 403：不要在 workflow 中自授予权限；由外部 GCP 管理员给 bootstrap principal
  补权后重新执行 TC-04。
- runtime KV 缺失：bootstrap apply 尚未成功，先完成 TC-06。
- state 初始化失败：只检查 `CICD/<env>/iac_state` 的五个字段，不把 GCP
  OAuth token 当作 state credentials。
- PROD 未等待审批：检查 job 的 `environment.name` 是否为 `prod`，以及仓库的
  protected Environment 规则。
