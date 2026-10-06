# AI Aggregator v1 provider matrix

`workflow_dispatch` chooses the environment and cloud. `environment` is a
lowercase string (default `uat`), and `provider` defaults to `gcp`, with
`aws`, `vps`, `akamai-cloud`, and `existing` also available. GitOps declares
resource types, topology, lifecycle and service configuration; its legacy
`spec.infrastructure.provider` field does not choose the adapter job.

The workflow looks under `topology/<environment>/selfhost/ai-aggregator*.yaml`
for the requested `deployment_profile` and resource renderer format. Exactly
one compatible declaration is required. A missing or ambiguous template fails
before any credentials are loaded or resources are created; choosing a cloud
never reuses another cloud's resource schema. The checked-out GitOps commit is
pinned for the remaining jobs.

| Dispatch provider | Resource format | Adapter | Credentials |
| --- | --- | --- | --- |
| `gcp` (default) | `gcp-cloud` renderer | GCP Terraform | Vault JWT + Google WIF |
| `aws` | `aws-cloud` renderer | AWS Terraform | AWS OIDC + Vault |
| `vps` | `vultr-cloud` / `vps-cloud` renderer | VPS Terraform | Vault provider credential |
| `akamai-cloud` | `akamai-cloud` renderer | Isolated Akamai state namespaces | Vault provider and state credentials |
| `existing` | `cmdb/inventory` | Ansible on existing nodes | Existing inventory + Vault |

Each job generates a runner-local declaration under
`gitops/.runtime/<environment>/ai-aggregator.yaml`. The event inputs supply
its environment and provider; the checked-in templates are not modified.
Environment-scoped Vault paths, GCP authentication, observability labels and
Akamai Terraform state namespaces use the selected environment. Resource
paths and workdirs come from the compatible template.

`stage` and `activate` require YAML `spec.enabled: true`. A disabled declaration
can still be inspected with `plan` or provisioned with `apply`/`provision`.
Every adapter depends on the Ansible syntax-check job, so a failed preflight
cannot provision resources in parallel. Push and pull-request events validate
all declared templates; only an explicit dispatch deploys.

`existing` supports `plan`, `stage` and `activate` and never runs Terraform or
destroy. Its existing protected GitHub Environment is retained, defaulting to
`production`; `AI_AGGREGATOR_PERSISTENT_ENVIRONMENT` can select another approval
environment without changing the deployment namespace. AWS/GCP retain their
branch-scoped OIDC subjects; changing credential namespaces requires matching
Vault/WIF configuration for that environment.

Provider choices require compatible GitOps resource templates and runtime
credentials. The current GitOps templates cover GCP `single-node`, Akamai
`distributed`, and existing nodes for both profiles. Selecting AWS or VPS
requires adding the corresponding topology/resource contract first; the UI
choice alone does not create a missing declaration.
