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

Identity integration metadata uses a separate, purpose-scoped KV v2 namespace:
`kv/iam/<env>/<integration>/<account>/<purpose>`. The canonical helper is
`iam/bootstrap_identity_kv.sh`; provider-specific wrappers are provided for
GCP, AWS, Linode, Vultr, UCloud Global, and Grafana. The helper accepts a
mode-0600 JSON payload file, merges it with CAS protection, and supports
`--check` without writing. It never creates cloud resources or enables SSO.

OIDC is the default protocol. A SAML payload must be created only after the
provider account has been checked and its OIDC capability is documented as
unavailable. Protocol and evidence belong in the GitOps declaration, not in
secret values.

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
