# Migrate Multi-Cloud Auth to OIDC and Cleanup Pipeline Dependencies

## Overview
This task documents the changes applied to `platform-ops.yaml` to achieve two main goals:
1. **Security (Multi-Cloud OIDC)**:
   - For AWS (and future GCP/Azure): Use cloud-native OIDC JWT (e.g., `aws-actions/configure-aws-credentials`) to get short-lived credentials.
   - For VPS (Vultr): Continue using HashiCorp Vault (authenticated via GitHub JWT) to inject sensitive information like `VULTR_API_KEY` and S3 backend AK/SK (`TF_STATE_ACCESS_KEY`).
2. **Readability & Architecture**: Refactor the deployment job dependencies to clearly reflect a clean, parallelized execution path for application deployments and DNS switching.

## 1. Update Authentication (OIDC & Vault)
In `.github/workflows/platform-ops.yaml`:
- **AWS OIDC Setup**: Added `aws-actions/configure-aws-credentials@v4` in the `provision` job, guarded by `if: steps.route.outputs.cloud_provider == 'aws-cloud'`, using `aws-region: ap-northeast-1` and `role-to-assume: arn:aws:iam::950604983695:role/GithubAction_IAC_Deploy_Role`.
- **GCP/Azure Setup**: Placeholder comments added for `google-github-actions/auth` and `azure/login` guarded by their respective `cloud_provider` strings.
- **Credential Export**: Updated the `Export Terraform credentials` step to branch based on `cloud_provider`:
  - If `aws-cloud`, do not set `AWS_ACCESS_KEY_ID` manually (let the AWS action handle it).
  - If `vultr-vps`, set `AWS_ACCESS_KEY_ID` (for the S3 state backend) and `TF_VAR_vultr_api_key` from Vault.

## 2. Refactor Pipeline Execution Path
The pipeline was refactored to align all domains to follow this clear, parallel structure:

```text
provision 
  │
  └→ deploy_base 
       │
       ├→ deploy_web_saas (container spin-up) ───────────────┐
       ├→ initialize_web_saas_databases (DB migration) ──────┤
       │                                                     │
       ├→ deploy_infra_platform ─────────────────────────────┤
       ├→ deploy_agent_proxy ────────────────────────────────┤
       ├→ deploy_ai_workspace ───────────────────────────────┤
       │                                                     │
       └─────────────────────────────────────────────────────┴→ switch_dns & observe
```

Changes:
- Removed the standalone `observe_web_saas` job.
- Integrated the endpoint observation and Caddy cert backup logic directly into the `switch_dns` job.
- Ensured `switch_dns` explicitly waits for all relevant deployment jobs (`deploy_web_saas`, `initialize_web_saas_databases`, `deploy_infra_platform`, `deploy_agent_proxy`, `deploy_ai_workspace`) before switching traffic, serving as a robust traffic gate.
