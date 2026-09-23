# Shared Vault GCP OIDC prerequisites

This guide prepares the Vault authorization and KV contracts used by the
shared Vault deployment in GCP project `open-platform-prod`. GitHub Actions
uses the protected GitHub Environment `prod`, while Vault paths and Terraform
state use the logical `shared` scope. No Vault root token, unseal shares,
service-account JSON key, or permanent GCP credential belongs in GitHub.

## 1. Install only the shared Vault roles and policies

An authorized Vault administrator runs this from the checked-out
`platform-ops-toolkit` main branch. The default is a read-only check; `--apply`
writes just the two shared GCP roles and policies (not every repository role):

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

bash scripts/vault/bootstrap_shared_gcp_roles.sh --check
bash scripts/vault/bootstrap_shared_gcp_roles.sh --apply
bash scripts/vault/bootstrap_shared_gcp_roles.sh --check
```

The declarations are stored separately by role name:

- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-gcp-bootstrap-open-platform-prod.hcl`
- `scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod.json`
- `scripts/vault/policies/github-actions-platform-ops-toolkit-shared-gcp-oidc-open-platform-prod.hcl`

The bootstrap role is restricted to this repository, the `prod` GitHub
Environment, the bootstrap workflow, and `main`. It can read only the shared
bootstrap/state records and write the shared runtime OIDC record. The runtime
role can read only the shared runtime OIDC record and shared state record.

## 2. Prepare the shared Terraform state KV record

Obtain the backend endpoint, bucket, region, access key, and secret key from the
approved shared state-store operator/secret manager. Do not copy them into
Git, workflow inputs, or chat. Export them into the current shell from that
secure source, then write and verify the dedicated path:

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

SHARED_IAC_STATE_ACTION=write bash scripts/gcp/bootstrap_shared_iac_state_kv.sh
bash scripts/gcp/bootstrap_shared_iac_state_kv.sh
```

This writes KV v2 path `kv/CICD/shared/iac_state` with exactly these non-empty
fields:

```text
TF_STATE_ENDPOINT
TF_STATE_BUCKET
TF_STATE_REGION
TF_STATE_ACCESS_KEY
TF_STATE_SECRET_KEY
```

The script validates the complete record without printing any values. It
refuses to write if a field is absent; it does not invent state-store details
or copy credentials from another environment.

## 3. Prepare the one-time GCP bootstrap token

Use a GCP identity authorized by the project administrator to manage Workload
Identity Federation, service accounts and project IAM in `open-platform-prod`.
The bootstrap process is not self-elevating: if the identity lacks required
permissions, an existing project administrator must grant them out of band.
Do not grant Owner just for this workflow.

With an authorized Vault write session, write the short-lived ADC access token
to the exact shared/account path. The script obtains the token from local ADC
when `GCP_ACCESS_TOKEN` is not set and never prints its value:

```bash
export VAULT_ADDR=https://vault.svc.plus
vault login

GCP_ENVIRONMENT=shared \
GCP_ACCOUNT_ID=open-platform-prod \
GCP_PROJECT_ID=open-platform-prod \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh

GCP_BOOTSTRAP_ACTION=check \
GCP_ENVIRONMENT=shared \
GCP_ACCOUNT_ID=open-platform-prod \
GCP_PROJECT_ID=open-platform-prod \
bash scripts/gcp/bootstrap_gcp_auth_kv.sh
```

This initializes `kv/CICD/shared/gcp-bootstrap/open-platform-prod` with
`GCP_ACCESS_TOKEN` and `GCP_PROJECT_ID`. The shared helper rejects a different
project/account mapping and disables the `--auth-json` long-lived-key option.
KV v2 does not expire a value when the OAuth token's TTL expires. Therefore,
write the token shortly before running bootstrap `apply`. After an `apply`,
the workflow attempts to revoke it, deletes previous KV versions, and retains
only `GCP_PROJECT_ID`. If automatic cleanup fails, use the helper's
`GCP_BOOTSTRAP_ACTION=revoke` mode from an authorized local admin session.

## 4. Run the GitHub Actions bootstrap

In **Actions → GCP OIDC Bootstrap**, dispatch with:

```text
environment = shared
action      = plan
```

Inspect the plan. Refresh the short-lived token using the previous step if it
has expired, then dispatch:

```text
environment = shared
action      = apply
```

The job runs in the protected GitHub Environment `prod` (approval required),
creates the GCP WIF pool/provider and deploy service account, verifies the
identity, and writes runtime identity metadata to
`kv/shared/platform/oidc/open-platform-prod`.

## 5. Run Vault infrastructure plan/apply

After bootstrap apply succeeds, dispatch **Vault shared GCP infrastructure**:

```text
cloud_provider = gcp-cloud
deploy_action  = plan
```

Review that the plan contains the shared VPC/subnet, three `e2-custom-2-2048`
Vault VMs with static public IPv4 addresses, no Cloud NAT, TCP 443 on the
Gateway, and TCP 22 only from `35.79.83.48/32`. No public rule should expose
Vault API port 8200. If the plan is correct, dispatch again with
`deploy_action = apply` and complete the protected `prod` Environment approval.

This provisions infrastructure only. Installing/configuring Vault and
XConnect, DNS cutover, and manual per-node Vault initialization/unseal remain
separate operations. GitHub Actions must never receive root tokens or unseal
shares.
