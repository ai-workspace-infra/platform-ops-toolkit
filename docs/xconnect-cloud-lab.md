# XConnect cloud integration lab

Manual workflow: `.github/workflows/xconnect-cloud-lab.yml`. Default `dry-run`
checks immutable refs, private repository access, real source builds, topology and
Terraform schema. It creates no cloud resources. `apply` then reads Vault runtime
secrets, checks account prerequisites, and adds only a `t4g.small` AWS Spot Gateway
and `t4g.micro` AWS Spot One client to the reused UAT environment for one hour.
It performs joint data-plane checks and always cleans up. This workflow is an experimental cloud-lab controller, not the formal Zero
Accounts API or Portal and never becomes their configuration source.

The Gateway and One have the same independent Linux-node baseline and both run
external WireGuard and Xray. Gateway is `role=relay` / `relay/service`; One is
`role=controlled-client`. Gateway additionally provides forwarding, relay health,
and the private service probe. Cloud Run, Cloudflare Workers, and other
serverless/edge-function platforms are not Gateway deployment targets.

The final configuration flow is fixed: XConnect Zero Accounts (devices,
networks, policy, signed config) and the Zero Portal are the sole centralized
control/config source. Gateway consumes the relay/service projection; One consumes
the controlled-client projection. The temporary `xconnect-zero-lab` process is
co-located only to debug the API/runtime contract in the cloud and issue a
disposable test enrollment; it is explicitly not a formal Accounts or Portal
endpoint.

## Exact dispatch inputs

| Input | Required value |
|---|---|
| `mode` | `dry-run` (default), `apply`, or recovery `cleanup` |
| `iac_ref` | Full reviewed SHA containing `vpn-overlay/xconnect-lab` in `ai-workspace-infra/iac_modules` |
| `gitops_ref` | Full reviewed SHA containing `topology/uat/xconnect-lab.json` in `ai-workspace-infra/gitops` |
| `cli_ref` | Full reviewed SHA in private `ai-workspace-xstream/XConnect-One`, including the real CLI and experimental lab API harness |
| `xray_ref` | Full reviewed compatible SHA in `XTLS/Xray-core`; compiled as external Linux executable |
| `cleanup_run` | Empty except cleanup: exact `xcl-RUN_ID-ATTEMPT` from original run |

CLI baseline `70a77e5` alone does not contain the lab API harness and is intentionally
rejected. No arbitrary container or mock endpoint is substituted. The final four
SHAs must exist remotely before this workflow can run. Dispatch from a toolkit ref
accepted by BOTH the current Vault role and AWS role trust; do not weaken existing
trust policies just to run a feature branch.

## Authentication and Vault fields

CI uses GitHub OIDC JWT with audience `vault`, Vault address
`https://vault.svc.plus`, and the dedicated role
`github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab` through
the existing `hashicorp/vault-action@v4` pattern. There are no new static GitHub
cloud-credential secrets. Missing paths/fields are fatal.

The Vault administrator must re-run
`scripts/create_vault_service_repo_roles.sh` after enabling this workflow so the
dedicated role exists. Its `job_workflow_ref` is pinned to
`platform-ops-toolkit/.github/workflows/xconnect-cloud-lab.yml@refs/heads/main`;
it reuses the UAT data policy but cannot authenticate from another workflow or
branch. The workflow does not broaden or self-modify Vault role bindings.

| Vault KV v2 API path | Exact fields |
|---|---|
| `kv/data/CICD/github-app/daily-snapshot` | `app_private_key` |
| `kv/data/CICD/uat` | `TF_STATE_ENDPOINT`, `TF_STATE_BUCKET`, `TF_STATE_ACCESS_KEY`, `TF_STATE_SECRET_KEY`, `TF_STATE_REGION` |
| `kv/data/uat/xconnect-one` | `ADMIN_TOKEN` (at least 32 characters), `SIGNING_KEY` (base64 Ed25519 32-byte seed), `VLESS_ID` (UUID) |

Existing GitHub App client ID `Iv23liNwStpQIiXajhpb` must be installed with Contents
read on `ai-workspace-infra/{iac_modules,gitops}` AND separately on
`ai-workspace-xstream/XConnect-One`. Installation tokens are generated per owner;
the default repository token cannot read the private CLI repository. Existing
`CROSS_REPO_GH_TOKEN` is deliberately not used.

AWS uses native short-lived GitHub OIDC credentials, following existing workflows,
with the GitOps-declared role/account/region and `sts.amazonaws.com` audience. The
role needs SSM GetParameter plus EC2 read/create/delete for the two one-time ARM64 Spot
instances and their disposable security groups (including Spot service-linked role
availability). No Vultr credentials or provider are used. Backend credentials must
read/write only the intended `uat/xconnect-lab/` namespace, including list/get/put/
delete of `_leases/` objects for expiry recovery. Provisioning code does
not create roles, edit Vault policy, or bootstrap Spot account permissions.

The CI Vault role does not become the runtime controller identity: only three
runtime values are injected into root-owned mode-0600 files over SSH. No Vault,
GitHub, AWS or Vultr credential is copied to either VPS. Fresh SSH/WireGuard keys
and one-day TLS CA are scoped to the disposable run. Host SSH keys use first-use
pinning per fresh run; subsequent key changes fail. The CA is explicitly trusted
on the client; TLS verification is never disabled.

## Verification and cleanup

The real lab server installs the device peer before returning a disposable debug
enrollment. The CLI verifies a signed v1 configuration, runs external Xray and
wg-quick, and ACKs local readiness. Independent Gateway checks require the
`relay` marker, active wg-quick/Xray/Zero API TLS health, and a recent relay-side
WireGuard handshake. Client checks require `controlled-client`, a recent client-side
handshake, private ping and an exact run-specific HTTP body on `10.77.0.1:8080`.
Sync is tested, followed by tunnel down and a negative private HTTP check. Gateway
policy accepts only the intended UDP 127.0.0.1:51820 target through VLESS; public
WG UDP is closed.

State/plan/logs are private runner files, never uploaded. The S3 state survives a
runner failure. Every normal apply attempt triggers `always()` cleanup, including
partial Terraform failures. Cleanup validates the exact run namespace and state
resource ownership before destroy, then asserts empty state. Before apply a durable
nonsecret lease records the four pinned refs, exact run ID and 60-minute expiry.
A scheduled job every 15 minutes reads expired leases and dispatches `cleanup`;
the lease is removed only after empty state is verified. This provides recovery
after runner loss; schedules must be enabled on main and may be delayed by GitHub,
so expiry is not an exact billing cutoff. Manual `cleanup` with original refs and
exact identity remains available and deletes only that lab's saved resources.
Report cleanup failures as
resource leaks requiring action; never treat a successful connectivity test as
proof of cleanup.

Existing workflows, production resources, and existing repositories' working
copies are unaffected by this dedicated pipeline.
