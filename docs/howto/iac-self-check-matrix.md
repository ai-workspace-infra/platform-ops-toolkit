# IAC 自检矩阵

`IAC Self Check Matrix` 是统一多云状态契约的只读自检流水线。它覆盖
`aws-cloud`、`gcp-cloud`、`azure-cloud`、`vultr-vps` 和 `akamai-cloud` 五个
Terraform provider，并从同一个 registry、IAC module tree 与 GitOps 声明生成
矩阵摘要。

## 触发

在 GitHub Actions 中运行 `IAC Self Check Matrix`，保持：

```text
dry_run: true
vault_env_path: uat
project: svc.plus
cloud_providers: aws-cloud,gcp-cloud,azure-cloud,vultr-vps,akamai-cloud
```

`dry_run=false` 会被 workflow 的 prepare job 拒绝。此 workflow 不读取 Vault，
不申请云凭据，不调用 Terraform，不执行 `apply` 或 `destroy`，因此适合在合并
前后检查路由和声明覆盖范围。

## 检查内容

每个 provider 一个矩阵 job，检查：

- `config/iac_provider_registry.json` 中的 provisioner、Terraform module tree、GitOps provider 和 credential mode；
- `iac_modules/terraform-hcl-standard/<terraform_tree>` 是否存在 Terraform 文件，并列出模块目录；
- `gitops/resources/<project>/<env>/<gitops_provider>/*.yaml` 的声明数量、区域、资源和服务；
- 五级 state key：`terraform/<env>/platform-ops-toolkit/<provider>/<account>/self-check/terraform.tfstate`。

没有当前环境 GitOps 声明的 provider 会显示为 `WARN`，但只要 registry 和 module
tree 完整就不会阻断自检；未注册 provider、`existing` provider 或缺少 Terraform
module tree 才会失败。

## 摘要

每个矩阵 job 会上传 JSON 报告，最后的 `IAC self-check summary` 汇总：

```text
provider | result | Terraform module | account | regions | resources | services
```

摘要只描述覆盖范围，不代表云资源已经创建或变更。需要真实资源变更时，仍须使用
受审批保护的部署 workflow，并由对应 provider 的凭据和 state backend 完成单独的
Terraform `plan` / `apply` 流程。
