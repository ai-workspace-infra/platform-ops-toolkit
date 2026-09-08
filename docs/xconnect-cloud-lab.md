# Formal XConnect UAT integration validation

The `.github/workflows/xconnect-zero-cloud.yaml` deployment workflow consumes
reviewed GitOps/IAC commits and versioned GitHub Release artifacts. It does not
build application code or run the experimental Zero controller. Accounts is
the sole formal control/configuration source. Portal retains its current layout.

## Execution order

1. Validate immutable refs, GitOps topology, and deployed Accounts/Portal API
   boundaries. The anonymous Portal check must reach `ssr-console` and the
   actual session-aware Zero BFF, not the generic API origin.
2. Download and verify One, Gateway and external Xray release checksums.
3. Reuse the UAT account/default VPC/subnet; create one `t4g.small` Spot
   Gateway and one `t4g.micro` Spot Linux One, plus isolated security groups.
4. Install released runtimes and generate the Gateway WireGuard identity on
   the Gateway. Its private key never leaves that node.
5. Use the protected formal Accounts bootstrap API to provision the run-scoped
   network and one-use, role/device-bound Gateway and Linux One invitations.
6. Enroll the formal Gateway with its invitation; verify/apply signed relay
   config and start external Xray/WireGuard.
7. Enroll One with its formal invitation; verify/apply signed client config,
   then reconcile the Gateway peer set after the new device joins.
8. Verify identity-bound signed sync/ACK state, external services, exact-peer
   recent handshakes on both nodes, private ping and an exact run-specific
   HTTP marker over WireGuard over VLESS.
9. Keep the verified Gateway/Linux One pair until the reviewed one-hour lease
   expires, emitting only Gateway/Linux health summaries. Do not publish or
   observe a macOS/Windows desktop handoff; desktop confirmation is a separate
   manual operation and is not a workflow gate.
10. After expiry, destroy only this run's dedicated Terraform state and verify it is
   empty. Connectivity success and cleanup success are separate results.

The preparation of Gateway key material precedes invitation issuance, but
the Gateway data-plane service is started only after formal enrollment.
Each deployment/verification phase is a separate GitHub Actions step.

## Inputs and release boundary

| Input | Contract |
|---|---|
| `mode` | `dry-run`, `apply`, or recovery `cleanup` |
| `iac_ref` | Full reviewed commit SHA containing `vpn-overlay/xconnect-lab` |
| `gitops_ref` | Full reviewed commit SHA containing `vpn-overlay/uat/xconnect-lab.json` |
| `cli_release_tag` | GitOps-pinned XConnect-One version; `xconnect-linux-arm64` and `SHA256SUMS` |
| `gateway_release_tag` | GitOps-pinned XConnect-Gateway version; `xconnect-gateway-linux-arm64` and `SHA256SUMS` |
| `xray_release_tag` | GitOps-pinned official Xray ARM64 archive and digest |
| `cleanup_run` | Cleanup only: exact `xcl-RUN_ID-ATTEMPT` |

Full UAT delivery is initiated through `daily-main-snapshot.yaml`, which keeps
its daily schedule and publishes one immutable application TAG before deployment.
The combined UAT dispatch then resolves reviewed IAC/GitOps main commits to SHAs
and starts this lab with the topology's release versions. The lab itself has no
scheduled deployment and cannot authenticate to Vault from an untrusted branch.

## Credentials

GitHub OIDC JWT (`aud=vault`) authenticates to `https://vault.svc.plus` using
`github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab`, restricted to the
main-ref workflow. Do not widen that trust to run a branch.

| Vault KV v2 API path | Fields used by this workflow |
|---|---|
| `kv/data/CICD/github-app/daily-snapshot` | `app_private_key` |
| `kv/data/CICD/uat` | `TF_STATE_ENDPOINT`, `TF_STATE_BUCKET`, `TF_STATE_ACCESS_KEY`, `TF_STATE_SECRET_KEY`, `TF_STATE_REGION` |
| `kv/data/uat/xconnect-one` | `VLESS_ID`, `ZERO_SERVICE_TOKEN`, `ZERO_OWNER_EMAIL` |

The owner email must identify the account that will inspect the run in Portal.
Owner isolation is not bypassed to make another user's nodes visible.
Accounts signing-key injection belongs to the Accounts UAT deployment; this
workflow never exports that signing key to a Gateway, One, or browser.

Provider, Vault, GitHub and internal service credentials stay on the protected
runner. Nodes receive only their scoped invitations and runtime material.
No secrets, state files or Terraform logs are uploaded as artifacts.

## Evidence boundaries

Linux PASS proves only the explicit Linux checks. An HTTP 200 for the Portal
page or a valid anonymous BFF response does **not** prove an authenticated
user can list/manage their resources. That requires a signed-in Portal
acceptance check after deployment.

Accounts `recent_ack` is a recent configuration acknowledgement, not real-time
WireGuard link telemetry. Node enrollment records remain in Accounts after
Spot cleanup; they must not be presented as currently online.

The former macOS check counted any second peer and lacked external transport
access/TLS trust delivery. It is not part of this workflow. The workflow does
not upload a desktop handoff, open a desktop observation window, or block on
macOS/Windows acceptance. Any later desktop check must be performed manually
with separately delivered, identity-bound material and is not evidence for the
Linux cloud-lab PASS. No host-adapter/Packet Tunnel integration is required by
standalone One.
Policy enforcement, revocation and session-renewal acceptance are separate
checks; signed v1 sync alone does not prove them.

## Resource limits and recovery

Gateway is an independent Linux relay, never Cloud Run or a Worker. Both
cloud nodes are ARM64 one-time Spot, with encrypted disposable disks. Public
WireGuard UDP is closed. SSH is restricted to the runner /32.

Dedicated state: `uat/xconnect-lab/xcl-RUN_ID-ATTEMPT/terraform.tfstate`.
A nonsecret lease retains the run identity, refs, release pins and the reviewed
60-minute expiry. The workflow keeps a successfully verified pair until that
expiry, then runs the normal `always()` cleanup. Partial provisioning failures
may clean up earlier. The job ceiling is 90
minutes and a fresh AWS OIDC session is acquired before cleanup because the
initial session is one hour. An expiry tag does not independently terminate
EC2. The matching IaC module also configures a persistent absolute-expiry
systemd timer that powers off the one-time, terminate-policy Spot instances,
independently of the runner. Do not set `instance_initiated_shutdown_behavior`
on Spot: the provider attempts an unsupported attribute modification. Pin an
IaC revision containing the timer and the Spot-compatible omission. This
fallback releases the instances and their disposable root disks, but does not
replace Terraform cleanup of the remaining security groups and state lease.
After runner loss/cancellation, explicitly run recovery `cleanup` with
the original refs and exact run ID; old 60/120-minute cleanup leases remain
compatible and any cleanup failure is a potential resource leak.

### Safe Terraform failure diagnostics

Terraform plan/apply/destroy/validate use JSON diagnostics. Raw output remains
in runner-private, per-command `terraform-<command>.log` files, so cleanup does
not overwrite failed apply evidence. These logs are not uploaded as artifacts.
Actions annotations and the job summary expose only fixed allowlisted operation,
resource, error-code and attribute labels; never diagnostic text, state, plans,
credentials, URLs or provider request payloads. Unrecognized errors are reported
as `unclassified`, not printed verbatim. Runner-private logs disappear with the
runner; only the safe summary is retained by Actions.
Private output/state reads also capture stderr through that same safe summary.
If a state read fails, cleanup fails closed and explicitly reports that resource
release is unverified; it never destroys resources without validating ownership.
