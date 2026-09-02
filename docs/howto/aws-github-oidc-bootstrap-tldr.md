# AWS GitHub OIDC 首次 Bootstrap TL;DR

## 结论

首次修复 AWS GitHub OIDC 时，必须区分 GitOps 声明与临时 AWS 控制面凭据：

- GitOps 管理非敏感的 AWS 账号、区域、Role ARN、OIDC audience 和 GitHub `sub`；
- Vault 为 bootstrap 作业发放短期 AWS 凭据；
- 不得将 AWS root Access Key 长期存入 Vault KV、GitHub Secrets 或仓库。

当前生产 OIDC 声明在 GitOps：

```text
resources/svc.plus/prod/aws/github-actions-oidc.json
```

该文件是 `iac_modules` 与 `platform-ops-toolkit` 的共同配置源。它允许：

```text
repo:ai-workspace-infra/platform-ops-toolkit:ref:refs/heads/main
repo:ai-workspace-infra/platform-ops-toolkit:ref:refs/tags/v*
```

## Vault：现有生产 KV

保留现有基础设施凭据路径：

```text
kv/data/CICD/prod
```

该路径的现有必填字段是：

```text
VULTR_API_KEY
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
TF_STATE_REGION
SSH_PRIVATE_DEPLOY_KEY_B64
```

`TF_STATE_*` 仅用于 Terraform state 后端；它们不是 AWS IAM 管理凭据，不能用于修复
`GithubAction_IAC_Deploy_Role` 的信任策略。

## Vault：当前首次 bootstrap 路径

本次已创建两个生产 KV v2 路径：

```text
kv/data/CICD/prod/aws-bootstrap
kv/data/CICD/prod/iac_state
```

它们的职责必须分开：

| 路径 | 用途 | 允许的字段 |
| --- | --- | --- |
| `aws-bootstrap` | 一次性 AWS 控制面身份 | `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、可选 `AWS_SESSION_TOKEN` |
| `iac_state` | 现有基础设施与 Terraform state 后端 | `VULTR_API_KEY`、`TF_STATE_ENDPOINT`、`TF_STATE_BUCKET`、`TF_STATE_ACCESS_KEY`、`TF_STATE_SECRET_KEY`、`TF_STATE_REGION`、`SSH_PRIVATE_DEPLOY_KEY_B64` |

`iac_state` 不包含现有 Terraform identity state 或 bootstrap YAML。因此首次 OIDC 故障恢复
不能假设可从空 state 安全执行完整的 Terraform identity apply；恢复流水线只更新由 GitOps
声明生成的 IAM trust policy。后续常规 Terraform apply 再以现有 state 为准进行漂移校验。

首次 OIDC 恢复流水线只读取 `aws-bootstrap`，不读取 `iac_state`；后者继续由既有 IaC/state
流程按最小权限消费。两条路径都不能直接扩展给通用 PROD role、UAT role或普通应用部署工作流。

## Vault：目标状态

使用 Vault AWS Secrets Engine 发放短期凭据，而不是 KV：

```text
aws/config/root                         # 仅 Vault 管理员配置；流水线不可读取
aws/roles/iac-bootstrap-prod            # 动态 AWS 凭据角色
aws/creds/iac-bootstrap-prod            # bootstrap 作业读取的短期凭据
auth/jwt/role/github-actions-iac-bootstrap-prod
```

JWT role 必须绑定 GitHub Actions JWT，至少限制为：

```yaml
repository: ai-workspace-infra/platform-ops-toolkit
ref: refs/heads/main
audience: vault
```

动态凭据应只授予完成本次修复所需的 AWS IAM 权限：

```text
iam:GetRole
iam:UpdateAssumeRolePolicy
iam:GetOpenIDConnectProvider
iam:ListOpenIDConnectProviders
```

如 Terraform plan 显示需要读取或管理现有 OIDC Provider，可在同一个受限策略中加入相应
只读权限。不要用 AWS root 用户作为流水线身份。

## 一次性 bootstrap 流程

1. 使用 AWS 账户 `950604983695` 的 IAM Identity Center 管理员角色或经审批的
   break-glass 角色进入一次性执行环境。
2. 用 GitHub JWT 登录 Vault，从 `aws/creds/iac-bootstrap-prod` 读取短期
   `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` 与 `AWS_SESSION_TOKEN`。
3. 检出已合并的 `iac_modules/main` 和 `gitops/main`，设置配置路径：

   ```bash
   export BOOTSTRAP_CONFIG_PATH=/controlled/bootstrap.yaml
   export GITHUB_ACTIONS_OIDC_CONFIG_PATH=/controlled/gitops/resources/svc.plus/prod/aws/github-actions-oidc.json
   ```

4. `BOOTSTRAP_CONFIG_PATH` 指向受控 bootstrap YAML；它仍提供 account、region、state 与
   Terraform deploy role 的既有配置。OIDC 的账号、Role ARN 和允许的 GitHub subjects 则只从
   `GITHUB_ACTIONS_OIDC_CONFIG_PATH` 指向的 GitOps 声明读取。
5. 在 `terraform-hcl-standard/aws-cloud/bootstrap/identity` 先执行 `plan`。确认变更只涉及
   `GithubAction_IAC_Deploy_Role` 的 OIDC trust policy，再执行 `apply`。
6. 以新的生产 release tag 重跑 Selfhost Orchestrator，验证 `AssumeRoleWithWebIdentity`
   成功。
7. 结束 break-glass 会话并保留 Vault/AWS CloudTrail 审计记录；不要保留 root Key。

## 不推荐但可短期救援的方案

当前创建的 KV 路径是 Vault AWS Secrets Engine 建立前的受控过渡方案：

```text
kv/data/CICD/prod/aws-bootstrap
kv/data/CICD/prod/iac_state
```

`aws-bootstrap` 字段仅限：

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN             # 可选；使用 STS/IAM Identity Center 临时凭据时必须提供
```

`iac_state` 只放现有基础设施和 Terraform state 后端凭据，不能混入 AWS 控制面凭据。

两个路径均只授予 bootstrap JWT role、设置极短 TTL 或变更窗口，并在 apply 审计完成后立即删除
`aws-bootstrap` 的控制面凭据。最终仍应替换为 Vault 动态 AWS 凭据。

## 验收

- GitOps `github-actions-oidc.json` 已合并，且没有密钥；
- Terraform plan 没有创建或替换非 IAM/OIDC 资源；
- AWS Role trust policy 包含 `main` 与 `v*` 的两个生产 subject；
- 发布流水线能取得 OIDC 凭据；
- 没有 root Access Key 存在于 KV、GitHub Secrets、日志或仓库。
