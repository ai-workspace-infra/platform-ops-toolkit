# Vault authorization declarations

This directory is the source of truth for the Vault JWT policies and roles
provisioned by `../create_vault_service_repo_roles.sh`.

## Layout

- `policies/<policy-name>.hcl` contains the Vault KV capabilities.
- `roles/<role-name>.json` contains one concrete JWT role, including its
  `description`, GitHub OIDC trust claims, token settings, and policy names.
- `roles/README.md` documents the per-role declaration contract.

The parent script only validates and applies these files. It does not contain
role-specific authorization rules. The role `description` and `role_name`
metadata are removed before the JSON payload is sent to Vault.

## Adding a GCP account

For every new account, add the UAT and PROD policy/role declarations. Keep the
account identifier stable and readable (an email-like value is allowed), and
use the same identifier in the role name and Vault paths:

```text
kv/CICD/uat/gcp-bootstrap/<gcp_account_id>
kv/CICD/prod/gcp-bootstrap/<gcp_account_id>
kv/uat/platform/oidc/<gcp_account_id>
kv/prod/platform/oidc/<gcp_account_id>
```

Review role and policy changes as security-sensitive changes. Do not store
access tokens, private keys, or other secret values in this directory.

## Apply

Run with an authenticated Vault admin session:

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='hvs.***'
bash scripts/create_vault_service_repo_roles.sh
```
