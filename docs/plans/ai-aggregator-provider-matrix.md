# AI Aggregator v1 provider matrix

`platform-ops-toolkit/.github/workflows/ai-aggregator-v1.yml` treats the
GitOps `spec.infrastructure.provider` field as the source of truth. The
workflow does not default deployment to AWS. `workflow_dispatch.provider` is
an optional guard: `manifest` accepts the declaration, while `aws`, `gcp`, or
`vps` must exactly match it.

| GitOps provider | Adapter job | UAT lifecycle | Credential source |
| --- | --- | --- | --- |
| `aws` | AWS Spot adapter | ephemeral, 60 minutes | AWS OIDC + Vault |
| `gcp` | GCP Spot adapter | ephemeral, 60 minutes | GCP WIF settings from Vault + Vault |
| `vps` / `vultr-vps` | VPS adapter | contract-defined | provider credential from Vault |
| `existing` | no UAT provision job | Prod persistent nodes | existing CMDB + Vault |

Each adapter consumes the declared contract's `path`, `renderer`, and
`workdir`. Provider-specific authentication is isolated to the adapter; the
common flow is render → Terraform validate/apply → CMDB/inventory → Ansible
stage → verify → UAT destroy.

The GCP UAT contract declares one Gateway and four CPA nodes. CPA nodes use
`e2-medium` (2 vCPU / 4 GiB) by default, which is the minimum practical size
for XFCE, XRDP/browser OAuth, the CPA process, and node_exporter. A later
headless profile may use 2 vCPU / 2 GiB after measurement; it is not the
default for OAuth-capable CPA nodes.

The GCP adapter runs `deploy_ai_desktop.yml` only against the generated
`ai_aggregator_cpa` group and enables node_exporter. XRDP passwords are read
from `kv/data/uat/ai-aggregator/cpa/<id>#desktop_password` into an ephemeral
runner file when stage/activate is requested. The file is never uploaded as
an artifact and is removed after Ansible exits. OAuth bundles remain in the
same CPA Vault record under `oauth_bundle`.

Required provider-specific GitHub/Vault prerequisites are intentionally
configuration, not code: GCP WIF project/provider/service-account values and
`VAULT_GCP_JWT_ROLE`; VPS adapter credential and `VAULT_VPS_JWT_ROLE`; AWS
role and existing AWS Vault role. Missing prerequisites fail before resource
creation.
