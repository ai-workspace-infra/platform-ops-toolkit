# Formal XConnect UAT integration validation

The `.github/workflows/xconnect-cloud-lab.yml` deployment workflow consumes
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
9. If requested, publish the public desktop handoff after Linux PASS and
   observe the bounded Darwin/Windows join window; this remains separate from
   Linux acceptance.
10. If requested instead, publish the same public handoff and observe the
   Gateway/Linux One pair for bounded sync and exact-peer health summaries.
11. Always destroy only this run's dedicated Terraform state and verify it is
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
| `mac_join_window_minutes` | Compatibility field; `0` only until the external desktop stage is ready |
| `desktop_join_window_minutes` | `0`, `10`, or `20`; nonzero is apply-only and requires enabled, exact Darwin/Windows GitOps validation plus one or two canonical IPv4 `/32` ingress CIDRs |
| `node_observation_window_minutes` | `0`, `10`, or `20`; nonzero is apply-only and mutually exclusive with the desktop window; observes only the already-provisioned Gateway/Linux One pair |

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
access/TLS trust delivery. It has been removed as invalid acceptance evidence.
The optional desktop window is opened only after Linux PASS. The GitOps
declaration must set `spec.desktop_validation.enabled=true`,
`platforms=["darwin","windows"]` exactly, and one or two canonical IPv4 `/32`
CIDRs. The default `0` path passes an empty `desktop_ingress_cidrs` list to
IAC and leaves Linux behavior unchanged. `mac_join_window_minutes` remains a
compatibility input and accepts only `0`.

When the window is nonzero, the workflow first uploads an artifact retained for
one day containing only `ca.crt` and an allowlisted `desktop-handoff.json`.
That JSON contains run/expiry and network identity, Gateway public key and
endpoint, Accounts/Portal URLs, Gateway/Linux instance IDs and public/private
addresses, expected `one-darwin-${run}` and `one-windows-${run}` IDs, and the
private verification target plus exact run marker. It contains no invitation,
token, VLESS identifier, private key, or owner email. Invitations are created
locally by the UAT operator through Vault and formal Accounts bootstrap; they
are never placed in CI artifacts or logs.

The node observation window uses the same public handoff and artifact, but does
not require desktop ingress CIDRs or desktop validation. It keeps the two
already-provisioned Linux nodes in place, periodically runs Gateway `up` and
Linux One `sync`, and emits only a summary of the exact Gateway-to-Linux One
peer health. The two nonzero windows are mutually exclusive.

The optional observer refreshes Gateway `up` every 30 seconds and matches each
expected device ID to its public key in the verified/applied signed WireGuard
configuration before checking that exact peer's recent handshake. It reports
`UNVERIFIED` when the identity-bound peer handshake is absent. Peer count alone
cannot produce desktop success, and this observer does not replace the local
macOS/Windows ping and HTTP checks. Final desktop acceptance is explicitly a
local independent check. The window is capped at 20 minutes and exits before
the lease's +50-minute safety point; normal `always()` cleanup and the 1-hour
Spot limit remain in force.

Desktop runs still require scoped external TCP 443 ingress, a reachable
Gateway endpoint, public CA trust delivery, and exact device identity.
macOS/Windows are not covered by Linux PASS. No host-adapter/Packet Tunnel
integration is required by standalone One.
Policy enforcement, revocation and session-renewal acceptance are separate
checks; signed v1 sync alone does not prove them.

## Resource limits and recovery

Gateway is an independent Linux relay, never Cloud Run or a Worker. Both
cloud nodes are ARM64 one-time Spot, with encrypted disposable disks. Public
WireGuard UDP is closed. SSH is restricted to the runner /32.

Dedicated state: `uat/xconnect-lab/xcl-RUN_ID-ATTEMPT/terraform.tfstate`.
A nonsecret lease retains the run identity, refs, release pins and a 60-minute
expiry. Normal runs use `always()` cleanup, including partial provisioning
failures. An expiry tag does not independently terminate EC2. After runner
loss/cancellation, explicitly run recovery `cleanup` with the original refs
and exact run ID; report any cleanup failure as a potential resource leak.
