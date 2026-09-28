# Vultr VPS bootstrap

Vultr remains an optional Terraform provider. Its existing API credential is
kept in the environment-level Vault record:

```text
kv/data/CICD/<env>
VULTR_API_KEY
```

Terraform state credentials remain in the separate record:

```text
kv/data/CICD/<env>/iac_state
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
TF_STATE_REGION
```

Use the canonical helper for a write or a read-only check:

```bash
VULTR_ENVIRONMENT=uat VULTR_API_KEY='<short-lived-or-rotated-token>' \
  scripts/cloud/bootstrap/vultr-VPS/bootstrap_vultr_auth_kv.sh --write
VULTR_ENVIRONMENT=uat \
  scripts/cloud/bootstrap/vultr-VPS/bootstrap_vultr_auth_kv.sh --check
```

The helper patches only `VULTR_API_KEY`; it does not overwrite the other
environment-level fields and does not create any VPS. Keeping the established
path avoids a second, conflicting Vault record for this provider.
