# Akamai Cloud/Linode Vault KV 初始化 TL;DR

## 1. 需要准备什么

需要一个具备目标 KV 写权限和 JWT role/policy 管理权限的 Vault 管理会话，
以及 Akamai Cloud/Linode Cloud Manager 创建的 Personal Access Token。

必填运行时变量：

```bash
export VAULT_ADDR='https://vault.svc.plus'
export VAULT_TOKEN='***'
export LINODE_TOKEN='***'
export AKAMAI_ACCOUNT_UAT='<真实UAT账户名或ID>'
export AKAMAI_ACCOUNT_PROD='<真实PROD账户名或ID>'
```

`AKAMAI_ACCOUNT_UAT` 和 `AKAMAI_ACCOUNT_PROD` 可以是同一个真实账户值。不要填写
`primary`、`default` 或 `main`。

## 2. State KV 参数

当前 workflow 从每个环境读取以下字段：

```bash
export TF_STATE_ENDPOINT='https://s3.example.com'
export TF_STATE_BUCKET='terraform-state'
export TF_STATE_ACCESS_KEY='***'
export TF_STATE_SECRET_KEY='***'
export TF_STATE_REGION='us-east-1'
```

如果 UAT 与 PROD 使用不同的 state 服务，可以按环境分别设置，例如：

```bash
export TF_STATE_ENDPOINT_UAT='https://s3-uat.example.com'
export TF_STATE_ENDPOINT_PROD='https://s3-prod.example.com'
```

其他字段同样支持 `_UAT` 和 `_PROD` 后缀。带环境后缀的变量优先于通用变量。

## 3. 初始化

在仓库根目录执行：

```bash
bash docs/akamai-cloud/init-vault-kv.sh --apply --env all
```

该入口依次完成：

```text
写入 kv/CICD/uat/iac_state
写入 kv/CICD/prod/iac_state
创建 UAT/PROD Akamai JWT role 和 read-only policy
写入 kv/CICD/uat/akamai-cloud/<account>
写入 kv/CICD/prod/akamai-cloud/<account>
```

只检查、不写入：

```bash
bash docs/akamai-cloud/init-vault-kv.sh --check --env all
```

## 4. 预期 KV 结构

```text
kv/CICD/uat/akamai-cloud/<account>
└── LINODE_TOKEN

kv/CICD/prod/akamai-cloud/<account>
└── LINODE_TOKEN

kv/CICD/uat/iac_state
├── TF_STATE_ENDPOINT
├── TF_STATE_BUCKET
├── TF_STATE_ACCESS_KEY
├── TF_STATE_SECRET_KEY
└── TF_STATE_REGION

kv/CICD/prod/iac_state
├── TF_STATE_ENDPOINT
├── TF_STATE_BUCKET
├── TF_STATE_ACCESS_KEY
├── TF_STATE_SECRET_KEY
└── TF_STATE_REGION
```

Vault KV v2 的 CLI 路径不带 `data`：

```bash
vault kv get -mount=kv CICD/uat/akamai-cloud/<account>
vault kv get -mount=kv CICD/uat/iac_state
```

策略/API 路径带 `data`：

```text
kv/data/CICD/uat/akamai-cloud/<account>
kv/data/CICD/uat/iac_state
```

## 5. 后续 workflow state key

凭据加载成功后，Akamai workflow 按以下规则生成 state object key：

```text
terraform/<environment>/<project>/akamai-cloud/<account>/<workspace>/terraform.tfstate
```

例如：

```text
terraform/uat/svc.plus/akamai-cloud/acme-account/ai-workspace/terraform.tfstate
```

不要在 Vault 中另外存 `TF_STATE_KEY`，避免项目和 workspace 被错误复用。

## 6. 验收

```bash
bash docs/akamai-cloud/init-vault-kv.sh --check --env all
```

然后通过 GitHub Actions 执行一次 `plan`，确认：

- `/v4/profile` 返回成功；
- UAT role 不能读取 PROD KV；
- state 使用五级 key 和 `.tflock`；
- `LINODE_TOKEN`、`TF_STATE_SECRET_KEY` 不出现在日志或 artifact；
- 首次接管资源的 plan 为 `0 to add / 0 to change / 0 to destroy`。
