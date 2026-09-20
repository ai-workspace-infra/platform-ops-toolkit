# AI Aggregator v1 minimal Vault KV contract

This contract applies independently to `uat` and `prod` under the Vault
server at `https://vault.svc.plus`.

## Approved paths

```text
kv/<env>/ai-aggregator/database/new-api
kv/<env>/ai-aggregator/database/litellm
kv/<env>/ai-aggregator/gateway/caddy
kv/<env>/ai-aggregator/gateway/new-api
kv/<env>/ai-aggregator/gateway/litellm
kv/<env>/ai-aggregator/litellm/providers/openai
kv/<env>/ai-aggregator/litellm/providers/anthropic
kv/<env>/ai-aggregator/litellm/providers/xai
```

The KV v2 API uses `kv/data/<env>/ai-aggregator/...`. Runtime configuration
references use the logical path without `data/`.

| Logical path | Required fields | Consumer |
|---|---|---|
| `database/new-api` | `dsn` | New API |
| `database/litellm` | `dsn` | LiteLLM |
| `gateway/caddy` | `admin_basic_auth_hash` | Caddy |
| `gateway/new-api` | `session_secret`, `crypto_secret`, `jwt_private_key`, `jwt_issuer`, `jwt_audience` | New API |
| `gateway/litellm` | `master_key`, `proxy_secret` | LiteLLM |
| `litellm/providers/<provider>` | `endpoint`, `api_key` | LiteLLM |

Only `openai`, `anthropic`, and `xai` provider records are in v1.

## Explicitly forbidden paths

New automation must not create or read:

```text
kv/<env>/ai-aggregator/accounts/*
kv/<env>/ai-aggregator/instances/*
kv/<env>/ai-aggregator/clients/*
kv/<env>/ai-aggregator/cpa/*
kv/<env>/ai-aggregator/database/backup
```

CPA OAuth bundles stay in the corresponding node's encrypted local auth
directory. Client token hashes, account/instance metadata, JWT `jti` state and
revocation state belong in PostgreSQL. Existing deprecated records are not
deleted by CI; deletion requires a separately approved migration.

## Policy boundary

- UAT and Prod identities are separate and may read only their own environment.
- Gateway identities read only the approved database, gateway and provider
  paths required by their service.
- CPA identities do not need Vault access for OAuth or channel credentials.
- CI may initialize empty records only through an explicitly approved operator
  action; normal deployment roles have no delete capability.
- Secret values must not appear in Git, Terraform state, Ansible facts, systemd
  units, logs or CI artifacts.
