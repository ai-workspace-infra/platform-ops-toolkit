# UAT persistent XConnect Gateway

The UAT cloud workflow supports a persistent, non-IaC Gateway for the
`TW-XConnect.onwalk.net` entrypoint. In this mode the workflow creates only one
`t4g.micro` one-time Spot Linux One in the existing UAT network. It never
creates, updates, or destroys the persistent Gateway host.

## Ownership

```text
Vault:   kv/prod/ulighthost-xconnect/TW-XConnect.onwalk.net
         ├─ host / user / ssh_private_key_b64
         └─ endpoint metadata (sensitive values remain in Vault)

GitOps:  public transport and protocol declaration only
AWS:     one disposable t4g.micro Spot, one-hour lease
Gateway: TW-XConnect.onwalk.net, external Linux relay/service
```

The persistent host is outside Terraform ownership. Its Gateway state,
WireGuard private key, TLS private key and runtime files remain on that host.
The workflow reads only the Vault fields required for SSH and enrollment; no
secret is written to GitOps, Actions artifacts, or the public desktop handoff.

## Workflow dispatch

Run `.github/workflows/xconnect-zero-cloud.yaml` with:

```text
mode=apply
gateway_provider=external
external_gateway_id=gw-uat-tw-xconnect
external_network_id=net_uat-tw-xconnect
external_gateway_server_name=TW-XConnect.onwalk.net
```

The workflow then performs:

1. UAT readiness and immutable release checks.
2. Creation of one UAT Linux One Spot and its one-hour expiry timer.
3. Formal Accounts bootstrap for the stable network and a short-lived Linux
   One invitation. The external Gateway is not re-enrolled.
4. Linux One enrollment, signed configuration sync, ACK and Gateway peer
   reconciliation over the formal Accounts API.
5. TCP 443 TLS reachability, Xray/WireGuard service checks, exact peer
   handshake, private ping and private HTTP checks.
6. Observation until the One lease expires, followed by exact-run cleanup of
   the One Spot state only.

The current stable transport is VLESS/TLS on TCP 443. Public WireGuard UDP
51820 is not opened. XHTTP and Reality remain future transport profiles.

## Failure boundary

If the One Spot cannot be created or the data-plane checks fail, the workflow
cleans only resources present in that run's Terraform state. The external
Gateway is represented by the `external` provider mode and is therefore not an
destroyable Terraform resource.
