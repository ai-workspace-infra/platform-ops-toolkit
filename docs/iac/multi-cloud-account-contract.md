# Multi-cloud account contract

This contract makes the cloud account a first-class deployment boundary. A
provider may have many accounts in the same environment; each resource row
selects one concrete account, and the selected identity must match the
provider's authentication result before Terraform can run.

## Identity and state key

The canonical Terraform state hierarchy remains:

```text
terraform/<env>/<project>/<provider>/<concrete-account>/<workspace>/terraform.tfstate
```

Use a provider's real, stable identifier in `<concrete-account>`: AWS's 12
digit account ID, a GCP account/project identity, an Akamai Cloud account name,
or the provider's concrete organization/project ID. Do not use values such as
`primary`, `default`, or `main`. A state key is never selected from a secret or
from a provider response after Terraform has initialized.

GitOps resource rows own the provider and account selection. A future resource
may use another account of the same provider without changing the adapter; it
gets its own account declaration, credential binding, state key, and least-
privilege policy prefix.

## Credential boundaries

| Provider | Account identity to validate | Credential pattern | Current multi-account readiness |
| --- | --- | --- | --- |
| AWS | `account_id` (12 digits) | GitHub OIDC to an IAM role in that account; bootstrap credentials are temporary only | Runtime now fails closed unless `cloud_account` equals the GitOps OIDC account. One AWS account per environment is currently supported; bootstrap secret and declaration selection must become account-scoped before adding a second. |
| GCP | stable `gcp_account_id` plus `project_id` | GitHub OIDC → Vault JWT → Google WIF | Account-specific bootstrap/runtime Vault paths and roles exist; verify project and authenticated identity before any write. |
| Azure | `tenant_id`, `subscription_id`, and client/application ID | GitHub OIDC federated identity; no client secret | Not ready: Selfhost currently contains placeholder IDs. Replace them with account-selected GitOps identity records and assert active tenant/subscription before Terraform. |
| Vultr VPS | concrete Vultr account identifier | Vault-held `VULTR_API_KEY` | Not ready for multiple accounts: Selfhost reads one environment-level token and has no authenticated-account check. Move the key/role to environment/account scope and validate account identity. |
| Akamai Cloud | concrete Akamai account name/ID | Vault-held `LINODE_TOKEN` | Account-specific KV and JWT role exist; each token is intentionally account-wide, so bind one concrete account per role and reject aliases. |
| UCloud | concrete project/account ID | Vault-held UCloud API credentials | Not ready for multiple accounts: Selfhost reads the environment-level base path. Move credentials/project identity to environment/account scope and validate the returned project. |
| ULightHost existing | concrete inventory owner/account | Vault-held host connection facts | Inventory-only; identify the owner per record and never invoke Terraform. |

Provider credentials are never used as Terraform backend credentials. All
providers read the environment's `kv/CICD/<env>/iac_state` contract for the
S3-compatible backend. The AWS state role must be restricted to the requested
environment/project/provider/account/workspace prefixes, including its
`.tflock` objects.

## Fail-closed checks

Before `plan` or `apply`, the adapter must:

1. Resolve the account from the GitOps row and reject missing or alias values.
2. Load only that account's GitOps identity declaration and Vault credential
   path/role.
3. Compare the provider's authenticated identity with the selected account.
4. Derive the state key from the same account value and verify the lockfile
   scope.
5. Stop before Terraform if any provider, account, environment, project, or
   state-key values disagree.

Do not use one environment-wide provider token for multiple accounts. A
multi-account workflow dispatch may select accounts for different providers,
but each row remains independently bound to its own concrete account and
least-privilege credential.

## Current UAT AWS correction

The UAT AWS credentials currently resolve to account `081434641398`. The UAT
GitOps OIDC declaration must therefore use:

```text
account_id: 081434641398
role_arn: arn:aws:iam::081434641398:role/GithubAction_IAC_Deploy_Role
```

Production remains on its independently declared account. Changing the UAT
account declaration does not change production or migrate any Terraform state.

## Migration work still required for full account-scoped bootstrap

The current AWS recovery workflow and Vault policy use one bootstrap KV record
per environment (`CICD/<env>/aws-bootstrap`). Before adding a second AWS
account in the same environment, move to
`CICD/<env>/aws-bootstrap/<account_id>`, use one JWT role/policy per account,
and select a GitOps declaration such as
`resources/svc.plus/<env>/aws/accounts/<account_id>/github-actions-oidc.json`.
The existing environment-level declaration is retained only for the current
single-account profile. Vultr's general deployment path reads an
environment-level `VULTR_API_KEY`; UCloud reads credentials from that same
environment base. Both must move to account-specific paths and identity checks
before a second account can be selected. Azure's current placeholder IDs must
be replaced with per-account non-secret GitOps identity records before its
adapter is enabled.

Do not claim a provider is multi-account-enabled just because its Terraform
tree exists. It is enabled only after account selection, account-scoped secret
or federation, authenticated identity verification, a distinct state prefix,
least-privilege policy, and a mismatch regression test are all present.

These are explicit prerequisites; the provider registry listing a provider
does not by itself prove that its runtime adapter is safe for multiple
accounts.
