# Akamai UAT migration preflight

This manual workflow inventories the six UAT Akamai namespaces, the historical
shared state, and matching Linode instances/firewalls. It is read-only: it runs
Terraform backend initialization plus `terraform show -json`, S3 object-version
metadata reads, and Linode API `GET` requests. Terraform JSON is parsed in memory
and projected to allowlisted identity fields; the raw output is never printed or
uploaded. It never
runs a Terraform plan/apply, state import/move/remove/push, or resource deletion.

## Scope and state keys

The workflow always uses the concrete UAT account `manbuzhe2026`, reads provider
credentials from `kv/data/CICD/uat/akamai-cloud/manbuzhe2026`, and reads the S3
compatible backend fields from `kv/data/CICD/uat/iac_state`.

It checks these six current state keys:

```text
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/web-saas/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/open-platform/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/ai-workspace/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/agent-proxy-jp/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/agent-proxy-us/terraform.tfstate
terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/agent-proxy-sg/terraform.tfstate
```

The legacy candidate is derived from the historical UAT router at commit
`77d3a51f5b39f420ebee4fe07a22b442ddd3b206`: its UAT Akamai `target_domains=all`
path set `rf=selfhost`, used
`terraform/${deployment_env}/${STATE_PROJECT}/${cloud_provider}/${account}/${rf}/terraform.tfstate`,
and set `STATE_PROJECT=platform-ops-toolkit`. The same commit's environment
defaults set the UAT account to `manbuzhe2026`. The resulting exact candidate is:

```text
terraform/uat/platform-ops-toolkit/akamai-cloud/manbuzhe2026/selfhost/terraform.tfstate
```

The script records the source commit/path in the sanitized JSON. It does not
guess other historical keys or write to any candidate.

## Run

First merge the implementation PR to `main`. The UAT Vault JWT role is bound to
the workflow path and `refs/heads/main`; after merge, update that role using the
normal administrator bootstrap process so the new workflow is in its
`job_workflow_ref` allowlist:

```bash
export VAULT_ADDR='https://vault.svc.plus'
export VAULT_TOKEN='<Vault policy/role administrator token>'
export AKAMAI_ACCOUNT_UAT='manbuzhe2026'
bash scripts/vault/bootstrap_akamai_oidc_roles.sh --apply --env uat
```

Then open **Actions → Akamai UAT migration preflight → Run workflow**, select
`main`, and start it. The workflow is `workflow_dispatch` only and has no
mutable operation inputs. It uses GitHub OIDC to read the UAT Akamai token and
state KV values, checks out `gitops/main` and `iac_modules/main`, and runs the
read-only script. No workflow run is started by this change.

The run summary and seven-day JSON artifact contain only the state keys,
resource addresses/types/IDs/labels, instance region/plan/status, S3 version
metadata, mapping counts, and recommendations. Terraform state bodies and
credentials are never printed or uploaded.

## Per-namespace result

| Status | Meaning | Suggested next step |
| --- | --- | --- |
| `existing-in-legacy-state` | Linode instance ID and label match the old shared state | Review a one-to-one state adoption/move plan; do not create a duplicate |
| `existing-in-namespace-state` | The resource is already present in its canonical namespace state | Review the plan for drift; do not import or recreate it |
| `existing-unmanaged` | A matching instance exists in Linode but is absent from the old state | Review ownership, then plan a controlled import |
| `absent` | No matching instance, firewall, or old state resource was found | Review a one-namespace create plan |
| `ambiguous` | Duplicate labels/IDs, partial resources, or state/API disagreement | Stop and reconcile manually |

Any repeated expected label, a resource mapping to multiple namespaces, the old
`observability.svc.plus` source in any Akamai manifest/state, or `open-platform`
inside the cleanup set fails the run. `open-platform` is always reported as
persistent and not cleanup eligible.

## Legacy state retirement preview

`retirement_plan` includes the exact legacy key, current and prior S3 object
version metadata, whether versioning is enabled, a suggested archive key, and
an address-by-address mapping to the six target states. It reports counts for
one-to-one, unmapped, duplicate, and wrong-namespace mappings. The suggested
archive key is:

```text
terraform/archive/uat/platform-ops-toolkit/akamai-cloud/manbuzhe2026/selfhost/terraform.tfstate
```

The workflow only reads S3 version listings and archive object headers. It does
not copy or delete the state object. A backup prerequisite is satisfied only
when bucket versioning is enabled, the current object has a non-null VersionId,
and either an earlier object version exists or the suggested archive object is
present with matching size and ETag. The output reports these facts separately;
it never creates the archive copy.

Legacy state retirement is a later, separately reviewed phase. It is blocked
until all six namespace plans show `0 to add, 0 to change, 0 to destroy`, the
migration acceptance is recorded, the original
`ssh ubuntu@observability.svc.plus` host remained unchanged through acceptance,
and the state backup/version prerequisite is satisfied. This PR and workflow
never run `terraform state rm` or retire the legacy object.

### Future auditable retirement workflow interface

A future retirement workflow should be a separate `workflow_dispatch` workflow
with a fixed legacy key/account, a required expected current S3 VersionId, a
verified archive key/version/ETag, the six reviewed plan-run references, the
migration acceptance record, and evidence that the original observability host
was unchanged. Its first job should be read-only and regenerate the exact
one-to-one address mapping. A second job should require the protected
`uat-state-retirement` GitHub Environment approval, re-check the source object
VersionId and all six gates, and derive addresses only from the reviewed
mapping artifact. It must reject `open-platform`, unmapped resources, duplicate
identities, changed object versions, and user-supplied state addresses. Any
future state removal/archive action requires its own reviewed implementation;
this PR does not implement that workflow or grant a deletion path.
