---
name: multi-environment-delivery-and-release
description: Guidelines and routing rules for multi-environment (SIT/UAT/Prod) delivery, branching strategies, Vault OIDC isolation, and emergency secret handling in platform-ops-toolkit.
---

# Multi-Environment Delivery and Release Standard

When operating within the `platform-ops-toolkit` and interacting with GitHub Actions or Vault, you MUST adhere to the following environment and branch guidelines.

## 1. Environment Routing Rules

The workflow `selfhost-orchestrator.yml` routes selfhost infrastructure traffic to specific environments based on Git events. Never hardcode environments outside of these bounds:
- **`pull_request`** -> routes to **`sit`** environment (`sit/all-in-one.yaml`).
- **`main` or `release/*` push** -> routes to **`uat`** environment (`uat/web-saas-uat.yaml`).
- **`vMAJOR.MINOR.PATCH` tag** -> routes to **`prod`** environment (`prod/web-saas-prod.yaml`).

## 2. Vault Authentication & Secrets
- **DO NOT** store sensitive credentials in GitHub Actions Secrets.
- Authentication must use GitHub OIDC → Vault JWT.
- Environments are strictly isolated. Ensure you select the correct Vault role (`github-actions-platform-ops-toolkit-sit`, `-uat`, or `-prod`) depending on the context.

## 3. Branching Lifecycle
- Always use Pull Requests. **Do not push directly to `main` or `release/*`**.
- `feature/*` and `bugfix/*` MUST target `main`.
- `hotfix/*` MUST target `release/*`.
- Production deployments ONLY occur via annotated tags (`v*`).

## 4. Emergency Secret Leaks
If a secret is exposed in the repository:
1. **Revoke** immediately in Vault/Provider.
2. **Generate** a new credential.
3. Purge the Git history (e.g. using `git filter-repo`)—do not merely "delete" the file in a new commit.
