# UCloud provider credentials in Vault

The canonical UCloud provider credential record is a Vault KV v2 secret scoped
to one environment and one UCloud project:

```text
CLI: vault kv get kv/CICD/<env>/ucloud/<project_id>
API: kv/data/CICD/<env>/ucloud/<project_id>
```

Supported environment names are `sit`, `uat`, and `prod`. The record fields
are:

| Field | Purpose |
| --- | --- |
| `UCLOUD_PUBLIC_KEY` | UCloud API public key |
| `UCLOUD_PRIVATE_KEY` | UCloud API private key |
| `UCLOUD_PROJECT_ID` | UCloud project identifier; must match the path |
| `UCLOUD_REGION` | Default UCloud region for provider requests |

## Initialize or verify the record

Use a Vault token with write permission on the target path, or an authenticated
Vault CLI session. `curl` and `jq` are required. The script streams the secret
payload directly to Vault without writing a plaintext temporary file. It does
not run Terraform or change UCloud resources.

```bash
export VAULT_ADDR="https://vault.svc.plus"
export UCLOUD_ENVIRONMENT="uat"
export UCLOUD_PROJECT_ID="your-project-id"
export UCLOUD_REGION="cn-bj2"
read -r -s -p "UCloud public key: " UCLOUD_PUBLIC_KEY; echo
read -r -s -p "UCloud private key: " UCLOUD_PRIVATE_KEY; echo
export UCLOUD_PUBLIC_KEY UCLOUD_PRIVATE_KEY

scripts/ucloud/bootstrap_ucloud_auth_kv.sh
UCLOUD_BOOTSTRAP_ACTION=check scripts/ucloud/bootstrap_ucloud_auth_kv.sh
```

`write` replaces the KV record with the four fields above. Store credentials in
the environment only for the duration of the command; never commit them or put
them in shell history, GitOps YAML, Terraform variable files, or logs. To avoid
shell history, source values from a protected secret manager or read them
through a secure prompt before running the script.

## Current application boundary

UCloud is classified as `provisioner: terraform` with
`terraform_tree: ucloud`. The dedicated `ucloud-iac.yml` workflow reads this
credential path and the shared `iac_state` path, then renders and runs the
standard `ucloud/ucloud` Terraform modules. ULightHost remains classified as
`provisioner: existing` and is the only provider routed through
`external-inventory-state.yml`.
