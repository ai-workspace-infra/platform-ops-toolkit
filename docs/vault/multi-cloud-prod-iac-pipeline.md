# Provider-neutral Vault PROD IaC pipeline design

## Target topology

The production Vault Raft cluster has three stable logical node identities;
cloud/provider is an implementation detail declared per node:

| Node | XConnect role | Connectivity |
| --- | --- | --- |
| `vault-prod-0` | XConnect Gateway | Must publish a reachable XConnect entry or connect to an approved relay |
| `vault-prod-1` | XConnect One member | NAT egress **or** public IP to reach the Gateway |
| `vault-prod-2` | XConnect One member | NAT egress **or** public IP to reach the Gateway |

Nodes may be placed on any supported VPS/cloud provider and need not share one
provider. If a member has a public IP, firewall policy still denies public SSH
and Vault API access. A Gateway behind NAT needs an inbound mapping or an
outbound relay/rendezvous; NAT egress alone cannot make a listener reachable.

The only public inbound port is TCP `443`. The stable client endpoint is
`vault.svc.plus` served by Caddy with valid TLS:

```text
vault.svc.plus:443 -> Caddy (TLS termination) -> Vault API over loopback/private network
```

Do not publish Vault's port 8200 directly. Caddy is the only public HTTPS
application entry. Public firewall rules must deny SSH, Vault API 8200,
monitoring/exporter ports, and standalone XConnect ports. Node administration,
Vault peer traffic, and monitoring use XConnect One/Gateway or another private
zero-trust path.

The XConnect transport must either share the approved 443 entry without
weakening Caddy/Vault TLS routing, or the Gateway must establish an outbound
tunnel to an approved relay. Do not open another inbound port as a workaround.
Members may use NAT egress or their own public IP to reach this 443 entry; in
both cases, a public source address is not trusted by itself.
If Caddy is co-located on `vault-prod-0`, that host becomes a single failure
point for both the XConnect Gateway and public TLS entry even while the other
two Raft voters remain healthy. To avoid that, use redundant Caddy ingress
instances behind a provider-neutral health-checked entry/LB or managed DNS
failover. The ingress placement is a GitOps declaration, not an implicit
side-effect of the XConnect role.

## Workflow boundary

The dedicated GitHub Actions workflow should orchestrate IaC only:

1. Load a reviewed, provider-neutral GitOps cluster manifest defining the three
   node names, provider/account, location, size, provider-specific resource
   reference, state workspace, and XConnect role.
2. Validate exact membership: the three named nodes appear once;
   `vault-prod-0` is `gateway`; nodes 1 and 2 are `one`; no fourth voter is
   inferred from provider/resource names.
3. Generate a provider matrix from those declarations and invoke the existing
   provider pipeline for each node/resource group. Each provider authenticates
   only through its supported short-lived OIDC/WIF/STS mechanism and gets an
   isolated state key. A single provider's OIDC identity must not be reused
   across unrelated accounts.
4. `plan` all provider workspaces and summarize them before any apply. Apply
   requires protected GitHub Environment `prod` approval and must not offer an
   implicit destroy path.
5. IaC may install host prerequisites only through reviewed, non-secret
   bootstrap data. It must not initialize/unseal Vault, access the root token,
   or handle unseal shares.

Suggested state key shape:

```text
terraform/prod/<cloud-project-or-account>/<provider>/<account>/<vault-node>/terraform.tfstate
```

This prevents two providers or nodes from sharing a state object. Secrets such
as provider credentials, XConnect enrollment material, and state backend
credentials remain in Vault KV and are read only by provider-scoped Vault JWT
roles. Non-sensitive topology belongs in GitOps.

## Capability gap before implementation/use

The existing toolkit multi-cloud master accepts one `cloud_provider` per run;
it does not yet derive a per-node provider matrix from a single cluster
manifest. The GCP pipeline is also provider-specific. Therefore neither is yet
the required provider-neutral Vault service pipeline. Implementation needs:

- a provider-neutral GitOps cluster schema plus provider-specific resource
  declarations;
- renderer/workflow support for per-node provider, account, and state;
- a reviewed provider allowlist and isolated Vault JWT/WIF role per provider;
- a gateway reachability/firewall contract allowing only inbound TCP 443,
  never Vault API, SSH, monitoring, or standalone XConnect ports publicly;
- Caddy TLS certificate/renewal, private upstream, and ingress health/failover
  declarations for `vault.svc.plus`;
- CI fixtures covering same-provider and mixed-provider three-node plans.

Do not run production apply until those contracts exist, all three node
placements are explicitly selected in GitOps, and `plan` shows the intended
independent resources/states. Manual unseal is documented separately in
[`manual-unseal.md`](manual-unseal.md).
