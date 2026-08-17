# GitOps serverless routing backend

The serverless orchestrator uses `ai-workspace-infra/gitops` as the single source for
environment runtime topology values. For UAT the serverless mode file is:

```text
topology/uat/serverless/runtime-topology.yaml
```

The selfhost and hybrid pre-configurations are kept beside it at the `selfhost/` and `hybrid/`
paths. The mode directories intentionally sit outside a provider directory:
these declarations describe the complete runtime mode (DNS, VPS, Cloud Run, Supabase, and
Cloudflare boundaries), not a Cloudflare-only resource. Each Cloudflare matrix job checks out `main`, validates the declaration matching its
pipeline mode, and passes its absolute path to the portal or edge-gateway repository.
Application source and image versions are selected by the orchestrator's single `tag_ref` input;
GitOps routing remains on `main` because it is the environment configuration source rather than
an application artifact. Repository-local config files remain compatibility fallbacks for
standalone local builds; the orchestrator does not use those fallbacks.

The YAML declaration owns domains, Worker names, Pages project, route boundaries, and VPS/Cloud
Run origin policy. The workflow renders it to a temporary JSON document for existing consumers;
that generated file is never committed. Secrets are still loaded from Vault through GitHub OIDC
and are never committed to GitOps.
