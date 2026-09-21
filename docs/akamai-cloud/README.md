# Akamai Cloud/Linode Vault KV

本目录是 Akamai Cloud/Linode IAC 初始化的操作入口。Terraform 使用官方
`linode/linode` provider，凭据字段统一使用 `LINODE_TOKEN`；不使用
`AKAMAI_API`。

## 文件

- [`bootstrap-vault-kv-tldr.md`](bootstrap-vault-kv-tldr.md)：路径、字段和最短执行步骤。
- [`uat-prod-bootstrap-runbook.md`](uat-prod-bootstrap-runbook.md)：UAT/PROD Role、KV、workflow 与故障修复流程。
- [`uat-six-namespace-migration-plan.md`](uat-six-namespace-migration-plan.md)：面向人类和代码代理的 UAT 六 namespace、阶段 A-E、迁移门禁与仓库/Project/PR 关联规范。
- [UAT migration preflight](../howto/akamai-uat-migration-preflight.md)：只读核对 legacy state、六个 namespace、Linode 资源和后续 state retirement 门槛。
- [`init-vault-kv.sh`](init-vault-kv.sh)：初始化 state KV，并调用仓库中已有的 Akamai token/OIDC bootstrap。
- `scripts/vault/bootstrap_akamai_cloud_kv.sh`：只写入 Akamai provider token。
- `scripts/vault/bootstrap_akamai_oidc_roles.sh`：创建环境/账户绑定的 Vault JWT role 和 read-only policy。

`scripts/vault/` 是实现源；本目录脚本是统一入口，不应复制修改底层逻辑。

## 路径契约

```text
kv/CICD/<env>/akamai-cloud/<account>
  LINODE_TOKEN

kv/CICD/<env>/iac_state
  TF_STATE_ENDPOINT
  TF_STATE_BUCKET
  TF_STATE_ACCESS_KEY
  TF_STATE_SECRET_KEY
  TF_STATE_REGION
```

`<account>` 必须是真实 Akamai Cloud/Linode 账户名或 ID。`primary`、`default`、
`main` 等别名会被拒绝。`VAULT_TOKEN`、`AKAMAI_ACCOUNT_*` 是初始化时的运行时
输入，不写入 KV。

## 执行

```bash
export VAULT_ADDR='https://vault.svc.plus'
export VAULT_TOKEN='hvs.***'
export LINODE_TOKEN='***'
export AKAMAI_ACCOUNT_UAT='<真实账户名或ID>'
export AKAMAI_ACCOUNT_PROD='<真实账户名或ID>'
export TF_STATE_ENDPOINT='https://s3.example.com'
export TF_STATE_BUCKET='terraform-state'
export TF_STATE_ACCESS_KEY='***'
export TF_STATE_SECRET_KEY='***'
export TF_STATE_REGION='us-east-1'

bash docs/akamai-cloud/init-vault-kv.sh --apply --env all
bash docs/akamai-cloud/init-vault-kv.sh --check --env all
```

完成 KV 初始化后，按环境执行 `plan` / `apply` 的 workflow 参数和验证步骤，见
[`uat-prod-bootstrap-runbook.md`](uat-prod-bootstrap-runbook.md)。

如果 UAT/PROD 共用同一个实际账户，两个 `AKAMAI_ACCOUNT_*` 可以相同；Vault
路径和 GitHub OIDC role 仍按环境分开。

## 安全边界

- token 不写 GitHub Secrets、Git、Terraform 配置、plan artifact 或日志。
- `LINODE_TOKEN` 只用于 `linode/linode` provider。
- state 凭据只从 `kv/CICD/<env>/iac_state` 注入 workflow。
- state key 由 environment/project/cloud/account/workspace 五级参数生成。
- 当前 workflow 仍需要 `TF_STATE_ACCESS_KEY` 和 `TF_STATE_SECRET_KEY`；切换到 AWS OIDC → STS 后，需同步移除对应 KV 字段读取和 policy 权限。
