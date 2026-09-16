# 统一多云 IaC State 验证用例

本文是 `iac_modules`、`platform-ops-toolkit` 合并后的验收清单。测试分为
“无需云账号的代码契约测试”和“需要 Vault/对象存储/云账号的集成测试”两层。

## 统一前置条件

确认所有 Terraform state 参数只来自环境级 Vault KV：

```text
kv/data/CICD/<env>/iac_state
```

必填字段：

```text
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
TF_STATE_REGION
```

统一 state key：

```text
terraform/<env>/<project>/<cloud>/<account>/<workspace>/terraform.tfstate
```

不要把真实 token、Access Key 或 Secret Key 写入命令行、GitHub Variables、GitOps
YAML、tfvars、plan artifact 或测试日志。

## 自动化契约用例

在 `platform-ops-toolkit` 根目录执行：

```bash
python3 scripts/tests/test_iac_state_contract.py
bash .github/scripts/tests/gcp_oidc_bootstrap_contract_test.sh
bash .github/scripts/tests/platform_ops_action_runner_iac_dispatch_test.sh
bash .github/scripts/tests/platform_ops_dispatch_contract_test.sh
bash .github/scripts/tests/xconnect_cloud_lab_vault_role_contract_test.sh
```

验收结果：

| 用例 | 验证内容 | 预期 |
| --- | --- | --- |
| TC-01 | registry 包含 AWS/GCP/Azure/Vultr/Akamai/UCloud/Ulighthost | 7 个 provider，分类准确 |
| TC-02 | Terraform provider 生成五级 state key | 包含 env/project/cloud/account/workspace |
| TC-03 | `akamai-cloud` 路由到 `linode/linode` | 读取 `LINODE_TOKEN`，不读取 Cloudflare token |
| TC-04 | UCloud/Ulighthost adapter | `provisioner=existing`，无 Terraform tree/state |
| TC-05 | existing inventory 脱敏 | token/password/private key 不出现在 JSON |
| TC-06 | GCP/AWS/Vultr/Akamai workflow | `TF_STATE_*` 只从 `<env>/iac_state` 读取 |
| TC-07 | backend lock | backend 声明包含 `use_lockfile=true` |
| TC-08 | workflow gating | PR 上自动运行本测试，失败则禁止通过验证门禁 |

## Terraform 本地验证

在 `iac_modules` 根目录使用 fixture，不连接真实云账号：

```bash
python3 -m unittest terraform-hcl-standard/akamai-cloud/tests/test_generate.py
terraform -chdir=terraform-hcl-standard/akamai-cloud/envs/uat fmt -check -recursive
terraform -chdir=terraform-hcl-standard/akamai-cloud/envs/uat init -backend=false
terraform -chdir=terraform-hcl-standard/akamai-cloud/envs/uat validate
```

对 GCP/AWS/Azure/Vultr root module 重复 `fmt -check`、`init -backend=false`、
`validate`。`init -backend=false` 只验证配置，不会访问 state bucket 或创建云资源。

## Vault policy 隔离验证

使用只读的 policy 审计身份执行：

```bash
export VAULT_ADDR=https://vault.svc.plus
./scripts/vault/vault_layout_verify.py
```

预期：

- `sit` 只能读取 `kv/data/CICD/sit` 与 `kv/data/CICD/sit/iac_state`；
- `uat` 只能读取 `kv/data/CICD/uat` 与 `kv/data/CICD/uat/iac_state`；
- `prod` 只能读取 `kv/data/CICD/prod` 与 `kv/data/CICD/prod/iac_state`；
- 没有跨环境 state path、`kv/data/CICD/*` 通配符或写权限。

如果返回 `403`，说明线上 role 尚未部署仓库中的新增 policy；这不是允许回退到旧
`kv/data/CICD/<env>` state 字段的理由，应先发布 policy，再重跑验证。

## Akamai Cloud/Linode 集成验证

在 GitHub Actions 手动运行 `Akamai Cloud IaC`，先选择 `plan`：

1. `vault_env_path=uat`、`project=svc.plus`、`account_alias=primary`、
   `workspace=ai-workspace`。
2. 确认 Vault role 绑定 repository、`job_workflow_ref`、ref 和 environment。
3. 确认 workflow 成功调用 `/v4/profile`，日志只出现校验成功，不出现 token。
4. 确认初始化使用：

   ```text
   terraform/uat/svc.plus/akamai-cloud/primary/ai-workspace/terraform.tfstate
   ```

5. 确认 plan artifact、日志和 GitHub Actions summary 不含 `LINODE_TOKEN` 或
   `TF_STATE_SECRET_KEY`。
6. UAT plan 验收无漂移后，再按 GitHub Environment 审批执行 `apply`。

## S3-compatible lockfile 并发验证

使用测试环境 state key，启动两个相同的 plan/apply job：

1. Job A 使用同一五级 key 开始 Terraform 操作并保持 state lock；
2. Job B 使用完全相同的 key 启动；
3. Job B 必须等待或报 state lock 冲突，不能覆盖 Job A；
4. Job A 结束后确认 `.tflock` 被释放，并检查 state bucket versioning。

不得用生产资源做故障注入；只使用空测试 workspace 或明确的 UAT 资源组。

## Existing provider 验证

执行：

```bash
python3 scripts/iac/resolve_iac_contract.py \
  --environment uat --project svc.plus --provider ucloud \
  --account primary --workspace platform
```

预期 `provisioner=existing`、`terraform_tree` 为空、`state_key` 为空。随后运行
external inventory workflow，确认只生成：

```text
inventory/uat/svc.plus/ucloud/primary/platform.json
runs/uat/svc.plus/ucloud/primary/platform/<run-id>.json
```

日志中不得出现 Terraform `init`、`plan`、`apply` 或 `destroy`。

## 迁移验收

每个旧 state 迁移都必须保留旧对象版本，并记录：

```text
old key -> canonical key
```

迁移后按顺序执行：

```bash
terraform init -migrate-state
terraform validate
terraform plan
```

Terraform plan 预期为 `0 to add, 0 to change, 0 to destroy`。只有连续验证稳定后，
才清理旧 backend 配置或旧 state 对象。

