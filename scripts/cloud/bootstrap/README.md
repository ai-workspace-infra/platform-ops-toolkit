# Cloud bootstrap scripts

This directory is the canonical home for provider bootstrap and account
handoff helpers. Scripts here may initialize Vault KV prerequisites, validate
GitOps identity declarations, or reconcile a provider's OIDC control-plane
identity. They do not silently create application resources.

| Provider directory | Canonical responsibilities | Credential contract |
| --- | --- | --- |
| `aws/` | AWS GitHub OIDC recovery, state adoption, bootstrap KV | `kv/CICD/<env>/aws-bootstrap` for the one-time recovery credential; normal state uses `kv/CICD/<env>/iac_state` |
| `gcp/` | GCP bootstrap KV, shared state KV, account migration, OIDC declaration resolution | `kv/CICD/<env>/gcp-bootstrap/<account>` |
| `Akamai-Cloud/` | Akamai Cloud/Linode token and Vault JWT role bootstrap | `kv/CICD/<env>/akamai-cloud/<account>` with `LINODE_TOKEN` |
| `vultr-VPS/` | Vultr provider credential bootstrap; state remains separate | `kv/CICD/<env>` with `VULTR_API_KEY` |
| `ucloud/` | UCloud provider credential bootstrap | `kv/CICD/<env>/ucloud/<project>` |

All Terraform backends consume the shared `TF_STATE_*` contract from
`kv/CICD/<env>/iac_state`; provider credentials and state credentials must not
be conflated. The scripts default to read-only checks where practical. Any
write, apply, revoke, or state-adoption operation must be explicitly selected.

## Retired paths

The wrappers that used to forward here from `scripts/gcp/`, `scripts/iam/`,
`scripts/ucloud/`, `scripts/vault/bootstrap_akamai_*.sh` and
`.github/scripts/{aws,gcp}/` are removed. Call the canonical paths under this
directory; `scripts/tests/cloud_bootstrap_layout_contract_test.sh` fails if a
wrapper comes back.

## Safety rules

- Never print Vault or provider secret values.
- Do not place provider credentials in Terraform backend configuration.
- Do not invent a Terraform provider for an existing-only platform such as
  ULightHost; use the external inventory route.
- Keep provider/account/environment/workspace state keys explicit and scoped.
