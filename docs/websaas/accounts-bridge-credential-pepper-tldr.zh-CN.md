# Accounts Bridge Credential Pepper：TL;DR

## 结论

`BRIDGE_CREDENTIAL_TOKEN_PEPPER` 是 Accounts 服务端用于 HMAC-SHA256 哈希 Bridge 用户 Bearer token 的长期密钥。它不是用户 Bearer token，也不是 Bridge 运行时自动生成的临时值。

生产和 UAT 分别从以下 Vault KV v2 路径读取：

```text
kv/data/prod/accounts/runtime
kv/data/uat/accounts/runtime
```

字段名：

```text
BRIDGE_CREDENTIAL_TOKEN_PEPPER
```

## 相关字段

同一 `accounts/runtime` 路径还可能包含：

```text
INTERNAL_SERVICE_TOKEN
BRIDGE_REVIEW_AUTH_TOKEN
```

Bridge introspection 配置为：

```text
BRIDGE_ACCOUNTS_INTROSPECTION_URL=https://accounts.svc.plus/api/internal/bridge/credentials/introspect
BRIDGE_ACCOUNTS_SERVICE_TOKEN=<与 Accounts INTERNAL_SERVICE_TOKEN 相同>
```

## 生成与写入

首次创建 pepper：

```bash
openssl rand -hex 32
```

使用脚本安全写入，不会覆盖同一路径的其他字段：

```bash
scripts/websaas/bootstrap_accounts_runtime_kv.sh --write --env all
```

检查：

```bash
scripts/websaas/bootstrap_accounts_runtime_kv.sh --check --env all
```

指定已有 pepper：

```bash
scripts/websaas/bootstrap_accounts_runtime_kv.sh \
  --write --env all --pepper '<existing-long-lived-pepper>'
```

脚本使用 `vault kv patch`，因此只更新 `BRIDGE_CREDENTIAL_TOKEN_PEPPER`。

## 轮换规则

不要随意更换 pepper。Accounts 通过：

```text
HMAC-SHA256(BRIDGE_CREDENTIAL_TOKEN_PEPPER, bridge_token)
```

验证已有凭据。更换 pepper 会使历史 Bridge token 全部失效，需要重新签发用户凭据。

## 本次故障

现象：XWorkmate App 点击“连接”没有反应，Bridge 状态显示 `Endpoint: 不可用` / `Status: not configured`。

原因：

1. Bridge 的 Accounts introspection URL 配成了 Accounts 根地址，而不是 `/api/internal/bridge/credentials/introspect`。
2. Accounts 运行环境缺少 `BRIDGE_CREDENTIAL_TOKEN_PEPPER`，introspection 返回 `503 bridge_credential_unavailable`。

临时验证在 SecOPS 节点使用了 Bridge 静态 Bearer 校验；长期方案应补齐 Accounts 的 pepper 和 Secret 注入，再恢复 Accounts introspection。

## 验证命令

```bash
TOKEN='<bridge-user-bearer-token>'

curl -sS \
  -H "Authorization: Bearer ${TOKEN}" \
  http://10.79.0.7:8787/api/ping

curl -sS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"acp.capabilities","params":{}}' \
  http://10.79.0.7:8787/acp/rpc
```

预期：两个请求均返回 HTTP 200。
