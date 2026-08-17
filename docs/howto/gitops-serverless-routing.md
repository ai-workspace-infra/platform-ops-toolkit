# GitOps serverless routing backend

The serverless orchestrator uses `ai-workspace-infra/gitops` as the single source for
environment routing values. For UAT the file is:

```text
resources/svc.plus/uat/cloudflare/edge-routing.yaml
```

Each Cloudflare matrix job checks out `main`, validates the declaration, and passes its absolute
path to the portal or edge-gateway repository. Application source and image versions are selected
by the orchestrator's single `tag_ref` input; GitOps routing remains on `main` because it is the
environment configuration source rather than an application artifact. Repository-local config files
remain compatibility fallbacks for standalone local builds; the orchestrator does not use those
fallbacks.

The YAML declaration owns domains, Worker names, Pages project, route boundaries, and VPS/Cloud
Run origin policy. The workflow renders it to a temporary JSON document for existing consumers;
that generated file is never committed. Secrets are still loaded from Vault through GitHub OIDC
and are never committed to GitOps.
