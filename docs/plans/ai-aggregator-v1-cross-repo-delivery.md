# AI Aggregator v1 Cross-Repository Delivery

## Runtime boundaries

- `ai.onwalk.net` (UAT) / `ai.svc.plus` (Prod): Caddy -> APISIX -> New API -> CPA account instances.
- One AI hostname per environment: `/` and `/v1/*` route through APISIX to New API -> CPA; `/litellm/v1/*` routes through APISIX to LiteLLM -> official OpenAI, Anthropic, or xAI APIs.
- These are parallel aggregation chains under one Caddy security boundary; LiteLLM is not placed in front of CPA, and the two chains are not chained together.
- New API, LiteLLM, and CPA are never directly internet-facing.
- v1 excludes Bedrock, Vertex AI, and Azure AI Foundry.

## Topology profiles

Each environment has two mutually exclusive GitOps manifests, selected by the
`deployment_profile` input of `ai-aggregator-v1.yml`:

- `distributed`: the existing Gateway plus four independent CPA nodes. UAT
  keeps the AWS Spot contract and Prod keeps the existing persistent CMDB
  nodes.
- `single-node`: one host is declared with `roles: [gateway, cpa]` and runs
  APISIX, New API, LiteLLM, and all four CPA instances. UAT uses the GCP Spot
  contract and Prod uses an existing persistent host.

The workflow defaults to `single-node` for manual dispatch; push-based UAT
automation remains on `distributed` for backward compatibility. Both profiles
share the environment hostname, so they must never be activated concurrently.
Home-Lab remains a separate deployment and continues to use its internal
hostname.

## Source of truth

- `ai-workspace-infra/gitops`: environment domains, node lifecycle, CPA matrix, model channels, and Vault references.
- `ai-workspace-infra/iac_modules`: AWS Spot UAT resources and AWS/Vultr/GCP VPS adapter contract. The GCP single-node profile keeps its resource declaration in GitOps and renders it into the GCP Terraform workdir at runtime.
- `ai-workspace-infra/playbooks`: systemd, Caddy, PostgreSQL, Vault runtime injection, and Ansible deployment.
- `ai-workspace-service/knowledge`: architecture and operational documentation.

## Delivery policy

Pull requests run manifest, secret-scan, Terraform, Ansible, and Caddy validation. A merge to
`main` can run the UAT workflow when the repository variable `AI_AGGREGATOR_UAT_ENABLED=true`
and `AWS_IAC_ROLE_ARN` is configured. The UAT job creates AWS ARM64 Spot resources, deploys,
waits for manual OAuth enrollment, runs smoke tests, and always destroys the temporary state.
Prod is a protected, manual Ansible deployment against existing persistent vhost nodes; Terraform
must not destroy or replace those nodes.

## Credentials

All database DSNs, provider API keys, OAuth bundles, channel tokens, client tokens, and admin
password hashes are read from `https://vault.svc.plus` at runtime. No value is emitted to logs,
artifacts, Terraform state, or Git.
