# AI Aggregator v1 Cross-Repository Delivery

## Runtime boundaries

- `ai.onwalk.net` (UAT) / `ai.svc.plus` (Prod): Caddy -> APISIX -> New API -> CPA account instances.
- One AI hostname per environment: `/` and `/v1/*` route through APISIX to New API -> CPA; `/litellm/v1/*` routes through APISIX to LiteLLM -> official OpenAI, Anthropic, or xAI APIs.
- These are parallel aggregation chains under one Caddy security boundary; LiteLLM is not placed in front of CPA, and the two chains are not chained together.
- New API, LiteLLM, and CPA are never directly internet-facing.
- v1 excludes Bedrock, Vertex AI, and Azure AI Foundry.

## Topology profiles

The `environment`, `provider` and `deployment_profile` dispatch inputs select a
compatible GitOps resource template for `ai-aggregator-v1.yml`:

- `distributed`: a Gateway plus four independent CPA nodes, using the cloud
  resource format selected by the dispatch or existing inventory.
- `single-node`: one host is declared with `roles: [gateway, cpa]` and runs
  APISIX, New API, LiteLLM, and all four CPA instances, using a compatible
  cloud resource template or an existing persistent host.

Manual dispatch defaults to `provider=gcp`, `environment=uat` and
`deployment_profile=single-node`. The environment accepts arbitrary lowercase
names; GitOps supplies the corresponding resource schema and deployment form.
The cloud comes from the event input. Shared hostnames must not be activated
concurrently. Home-Lab continues to use its separately declared internal
hostname.

## Source of truth

- `ai-workspace-infra/gitops`: environment domains, node lifecycle, CPA matrix, model channels, and Vault references.
- `ai-workspace-infra/iac_modules`: provider renderers and Terraform resource modules. The GCP single-node resource template stays in GitOps and renders into the declared Terraform workdir at runtime.
- `ai-workspace-infra/playbooks`: systemd, Caddy, PostgreSQL, Vault runtime injection, and Ansible deployment.
- `ai-workspace-service/knowledge`: architecture and operational documentation.

## Delivery policy

Push and pull-request events validate all declared AI Aggregator templates.
Deployment requires `workflow_dispatch`; merges and tags do not implicitly
select an environment or create resources. The dispatcher resolves one
compatible resource template, generates a runner-local deployment declaration
with the input environment/provider, and pins the GitOps commit for all jobs.

`plan` checks Ansible syntax. `apply`/`provision` create declared ephemeral
resources. `stage`/`activate` require `spec.enabled: true` and depend on a
successful plan before any provisioning starts. This prevents the failed-plan
parallel deployment seen in run `37408925598`. Disabling the declaration remains
a deliberate stop condition rather than being overridden by CI.

Persistent existing-node deployment keeps its protected GitHub Environment and
never runs Terraform destroy. See [the provider matrix](ai-aggregator-provider-matrix.md)
for available resource formats, environment-scoped credentials and missing
resource-template behavior.

## Credentials

All database DSNs, provider API keys, OAuth bundles, channel tokens, client tokens, and admin
password hashes are read from `https://vault.svc.plus` at runtime. No value is emitted to logs,
artifacts, Terraform state, or Git.
