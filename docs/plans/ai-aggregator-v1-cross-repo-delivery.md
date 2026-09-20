# AI Aggregator v1 Cross-Repository Delivery

## Runtime boundaries

- `ai.onwalk.net` / `ai.svc.plus`: Caddy -> New API -> CPA account instances.
- `direct.ai.onwalk.net` / `direct.ai.svc.plus`: Caddy -> LiteLLM -> official OpenAI, Anthropic, or xAI APIs.
- These are parallel aggregation chains under one Caddy security boundary; LiteLLM is not placed in front of CPA, and the two chains are not chained together.
- New API, LiteLLM, and CPA are never directly internet-facing.
- v1 excludes Bedrock, Vertex AI, and Azure AI Foundry.

## Source of truth

- `x-evor/gitops`: environment domains, node lifecycle, CPA matrix, model channels, and Vault references.
- `ai-workspace-infra/iac_modules`: AWS Spot UAT resources and AWS/Vultr/GCP VPS adapter contract.
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
