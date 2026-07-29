# DNS-01 wildcard TLS reuse for Caddy and stunnel

## Decision

`onwalk.net` uses a publicly trusted wildcard certificate issued by Caddy
through Cloudflare DNS-01. It is not a self-signed certificate.

The domain-scoped Vault record is `kv/data/CICD/domains/onwalk.net`. Sit, UAT,
and production intentionally reuse the same wildcard private key while the
certificate is valid.

## Vault contract

| Field | Consumer |
| --- | --- |
| `caddy_data_tar_b64` | Caddy ACME account, certificate, and key state |
| `tls_fullchain_pem_b64` | Caddy-independent TLS servers, including stunnel server |
| `tls_cert_pem_b64` | Leaf-certificate consumers |
| `tls_key_pem_b64` | TLS server private-key consumers |
| `tls_ca_pem_b64` | Issuer/intermediate chain; not a stunnel trust anchor by itself |
| `tls_trust_bundle_pem_b64` | Public root trust bundle used by stunnel client verification |

`tls_trust_bundle_pem_b64` is operator-managed: the certificate backup task
must preserve it when it updates the Caddy-generated fields. It must contain
the public roots needed to validate the issued chain, not only the issuer
intermediate exported by Caddy.

## Restore targets

The restore task writes the public certificate material to the isolated,
versioned path below and atomically changes `current` only after validation:

```text
/etc/xcontrol/tls/onwalk.net/current/
  fullchain.pem
  cert.pem
  key.pem
  ca.pem
  trust-bundle.pem
```

The existing `stunnel/certs` self-signed playbook and its
`/etc/xcontrol/web-saas/certs` output remain in place. They are the deliberate
bootstrap TLS path for a first DNS-01 issuance and for a missing/incomplete
public certificate state. The public wildcard material must not overwrite that
directory.

## Stunnel target configuration

The stunnel server uses the public certificate:

```text
server-cert.pem <- /etc/xcontrol/tls/onwalk.net/current/fullchain.pem
server-key.pem  <- /etc/xcontrol/tls/onwalk.net/current/key.pem
```

The stunnel client remains on its internal compose endpoint but validates the
public TLS identity:

```ini
connect = stunnel-server:15433
verifyChain = yes
CAfile = /etc/stunnel/certs/public-ca-bundle.pem
checkHost = postgresql-uat.onwalk.net
sni = postgresql-uat.onwalk.net
```

`checkHost` and `sni` use `postgresql-<environment>.onwalk.net`, which is
covered by `*.onwalk.net`; they deliberately do not use the internal Docker
service name.

## First issuance path

There is no public certificate state on the first new deployment. The workflow
therefore must not require the public stunnel mount before Caddy has completed
DNS-01 issuance. The safe order is:

1. Bootstrap the host with the existing self-signed `stunnel/certs` material.
2. Caddy performs DNS-01 issuance for `onwalk.net` and `*.onwalk.net`.
3. Observe verifies the public endpoints.
4. Backup stores Caddy state and PEM material without overwriting the trust
   bundle.
5. A subsequent reconciliation switches stunnel to the public TLS material.

On rebuild with a certificate that has at least
`CADDY_CERT_RENEW_MARGIN_DAYS` (default 14) remaining, restore happens before
the deployment reconciliation, so Caddy and stunnel can both reuse the prior
certificate without an ACME request.

## Acceptance

- A rebuilt host restores `caddy_data` and the public PEM state before Caddy
  can submit an ACME order.
- stunnel client logs show a successful chain and hostname verification for
  `postgresql-<env>.onwalk.net` while connecting to `stunnel-server:15433`.
- First issuance succeeds with the temporary bootstrap material, then stores a
  complete domain record.
- A destroy/rebuild within the renewal margin makes no new ACME order.

## Validation record

- 2026-07-29: dispatched the complete UAT `web-saas` workflow from
  `feature/restore-domain-tls-material` with `run_full_stack=true`.
- Run [30428197694](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30428197694)
  stopped in the first `Load Vault secrets` step. Vault correctly rejected the
  feature-branch OIDC claim for the UAT role: `claim "ref" does not match any
  associated bound claim values`.
- No Terraform apply, host bootstrap, Doco-CD action, DNS switch, or endpoint
  observation ran. Do not weaken the UAT role to test a feature branch; the
  full chain must run after the reviewed PR is merged to `main`.
