# UAT persistent XConnect Gateway

The UAT cloud workflow supports a persistent, non-IaC Gateway for the
`tw-xconnect.svc.plus` entrypoint. In this mode the workflow creates only one
`t4g.micro` one-time Spot Linux One in the existing UAT network. It never
creates, updates, or destroys the persistent Gateway host.

## Ownership

```text
Vault:   kv/prod/ulighthost-xconnect/tw-xconnect.svc.plus
         ├─ host / user / ssh_private_key_b64
         └─ endpoint metadata (sensitive values remain in Vault)
TLS:     kv/CICD/domains/svc.plus
         ├─ tls_fullchain_pem_b64
         └─ tls_key_pem_b64

GitOps:  public transport and protocol declaration only
AWS:     one disposable t4g.micro Spot, one-hour lease
Gateway: tw-xconnect.svc.plus, external Linux relay/service
```

The persistent host is outside Terraform ownership. Its Gateway state,
binary, Xray runtime, WireGuard packages and domain TLS material are reconciled
by the UAT workflow over the Vault-authorized SSH channel. The workflow never
prints or commits the certificate or key.
WireGuard private key, TLS private key and runtime files remain on that host.
The workflow reads only the Vault fields required for SSH and enrollment; no
secret is written to GitOps, Actions artifacts, or the public desktop handoff.

## Workflow dispatch

Run `.github/workflows/xconnect-one-uat.yaml` with:

```text
mode=apply
gateway_provider=external
external_gateway_id=gw-uat-tw-xconnect
external_network_id=net_uat-tw-xconnect
external_gateway_server_name=tw-xconnect.svc.plus
```

The workflow then performs:

1. Resolve the fixed node records and the shared `svc.plus` fullchain/key from
   Vault.
2. Download and checksum-verify the pinned Gateway, Xray and One releases.
3. Install Gateway Xray/WireGuard runtime, inject TLS material, and initialize
   its local identity when `state.json` is absent.
4. Create formal Gateway and One invitations, then enroll both through
   Accounts.
5. Apply signed configuration, send ACK, verify exact peer handshake, private
   ping and private HTTP checks.

The current stable transport is VLESS/TLS on TCP 443. Public WireGuard UDP
51820 is not opened. XHTTP and Reality remain future transport profiles.

## Failure boundary

If the One Spot cannot be created or the data-plane checks fail, the workflow
cleans only resources present in that run's Terraform state. The external
Gateway is represented by the `external` provider mode and is therefore not an
destroyable Terraform resource.
