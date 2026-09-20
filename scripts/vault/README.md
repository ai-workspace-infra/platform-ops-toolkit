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

After GCP bootstrap, runtime IaC workflows authenticate with dedicated,
read-only Vault JWT roles:

```text
github-actions-platform-ops-toolkit-uat-gcp-oidc-<gcp_account_id>
github-actions-platform-ops-toolkit-prod-gcp-oidc-<gcp_account_id>
```

These roles can read only the matching environment's WIF provider, audience,
project, and deploy Service Account record. They never read the bootstrap
access token and never change AWS roles or policies.

Review role and policy changes as security-sensitive changes. Do not store
access tokens, private keys, or other secret values in this directory.

## Apply

Run with an authenticated Vault admin session:

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='hvs.***'
bash scripts/create_vault_service_repo_roles.sh
```

The same entrypoint can also manage the account-specific Akamai Cloud/Linode
OIDC role. Set the concrete account name or ID and select the environment:

```bash
export AKAMAI_ACCOUNT_PROD='actual-account'
bash scripts/create_vault_service_repo_roles.sh --apply --env prod
```

Use `--check` to verify static declarations and the dynamic Akamai role without
writing Vault:

```bash
export AKAMAI_ACCOUNT_PROD='actual-account'
bash scripts/create_vault_service_repo_roles.sh --check --env prod
```

When no `AKAMAI_ACCOUNT_UAT` or `AKAMAI_ACCOUNT_PROD` is provided, the entrypoint
keeps its previous behavior and skips dynamic Akamai role management. The
account-specific role name is:

```text
github-actions-platform-ops-toolkit-<env>-akamai-oidc-bootstrap-<account>
```

## Akamai Cloud/Linode account-specific role

The Akamai Cloud/Linode workflow uses the concrete account name or ID in both
the Vault path and the JWT role name. `primary`, `default`, and `main` are not
valid account values. Render and publish only the requested Akamai roles with:

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN='hvs.***'
export AKAMAI_ACCOUNT_UAT='actual-uat-account'
export AKAMAI_ACCOUNT_PROD='actual-prod-account'
bash scripts/vault/bootstrap_akamai_oidc_roles.sh --apply --env all
```

The script uses the repository and workflow claim bindings, creates read-only
policies for the account's `LINODE_TOKEN` record and environment state record,
and does not write any secret value. Run
`bootstrap_akamai_cloud_kv.sh --apply --env all` separately to write the
`LINODE_TOKEN` value.
