# XConnect Zero network bootstrap workflow

`.github/workflows/xconnect-zero-cloud.yaml` keeps its existing UAT `cloud-lab` and `existing-one` profiles. The additive `declared-network` profile bootstraps a PROD or custom Zero network from a reviewed GitOps YAML declaration; it does not create cloud compute or install a Gateway binary.

## Configuration and secret boundary

Non-sensitive network configuration belongs in GitOps under `vpn-overlay/networks/` and is selected by an immutable GitOps commit SHA. The declaration supplies the Accounts API URL, network ID/name/CIDR, Gateway ID/public WireGuard key/address/endpoint, transport SNI/kind/port/path/mode, and invitation lifetime. The selected `prod|custom` scope must match `metadata.environment`.

Sensitive values stay in Vault:

- `CICD/shared/xconnect`: `ZERO_SERVICE_TOKEN` and `VLESS_ID`. Owner email is non-sensitive and belongs in GitOps (`spec.zero.owner_email`); existing KV copies are no longer read by the declared-network profile.
- `CICD/github-app/daily-snapshot`: `app_private_key` for read-only GitOps checkout.
- `CICD/shared/xconnect-operator-invite/<network_id>-<run_id>-<attempt>`: unique, write-only from CI; stores the short-lived one-use `JOIN_URI` plus its network and Gateway IDs. CI has no read capability for invitations; the exact path is included in the Actions summary.

The dedicated JWT role `github-actions-platform-ops-toolkit-shared-xconnect-network` is bound to this workflow on `main` and GitHub Environment `prod`. Its policy cannot read UAT/PROD host credentials or read back invitations. The workflow selects the `prod` Environment; configure required reviewers in GitHub Environment settings if apply must wait for explicit approval. Add the role and policy through the repository's normal Vault role provisioning entrypoint before dispatching this profile.

## GitOps declaration shape

```yaml
apiVersion: gitops.svc.plus/v1alpha1
kind: XConnectNetwork
metadata:
  name: shared-vault
  environment: prod # or custom
spec:
  zero:
    accounts_api_url: https://accounts.svc.plus
    owner_email: haitaopan@xworktech.com
  network:
    id: net_shared_vault
    display_name: Shared Vault
    cidr: 10.90.0.0/24
  gateway:
    id: gw-vault-prod-0
    device_id: vault-prod-0
    wireguard_public_key: <public-key-produced-by-the-Gateway>
    wireguard_address: 10.90.0.1/32
    endpoint_host: vault.svc.plus
    endpoint_port: 51820
    transport:
      server_name: vault.svc.plus
      kind: vless-xhttp
      port: 443
      path: /xconnect
      mode: auto
      host: vault.svc.plus
  invitation_ttl_minutes: 15
```

Replace the example API origin with the real environment's API endpoint; do not put tokens, private keys, or invitation URIs in GitOps. The workflow rejects malformed IDs, non-HTTPS API URLs, mismatched target scope, invalid CIDRs, and Gateway addresses outside the network.

## Dispatch

1. Add and review the declaration in GitOps, then record its full commit SHA.
2. Run **XConnect Zero Cloud and Network Bootstrap** with `deployment_profile=declared-network`, `network_environment=prod|custom`, `network_manifest=vpn-overlay/networks/<declaration>.yaml`, and the immutable GitOps SHA.
3. Run `mode=dry-run` first. This validates the declaration and constructs a private request only.
4. After reviewing the diff/inputs, run `mode=apply`. The GitHub `prod` Environment rules apply (including reviewer approval if configured). The job creates the network and a declaration-TTL one-use Linux Gateway invite, then writes that invite to a unique network/run-scoped Vault path. CI cannot read it back.
5. An operator retrieves and consumes the invitation using an independently authorized Vault session. Gateway installation/enrollment, host SSH, One enrollment, monitoring, and network deletion remain separate stages; this profile intentionally does not perform them.

Do not use this profile to transfer an existing network between owners or to delete a network. Such operations require a separately reviewed Accounts API capability.
