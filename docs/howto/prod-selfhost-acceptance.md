# PROD Selfhost acceptance

| Item | Success condition |
| --- | --- |
| Doco-CD / containers | Fresh successful synchronization, healthy target containers, Caddy stays running |
| Selfhost HTTPS | Direct CMDB target IP, verified TLS certificate and successful HTTPS response |
| API Server | Accounts and Billing health/readiness endpoints return 200 |
| DB availability | Read-only `SELECT 1` succeeds in the target account database |
| DB consistency | Read-only comparison matches count, email, password hash and Proxy UUID |

PRs, schema and release tags are preparation records, not separate runtime acceptance items.
Fixed source/target identities and safe execution contracts still protect the operations.
Manual login/subscription/quota/billing/single-writer testing is independent of workflow verdicts.
DNS only changes via explicit Toolkit DNS parameters or manual operations; neither
availability nor data comparison changes DNS. Cloudflare continues serving the frontends.

`selfhost-orchestrator.yml` runs PROD availability after a successful Web SaaS
deployment, independently of UAT baseline capture and DNS changes. It also provides
`operation=native-availability` for checks against the existing canonical PROD host
without infrastructure provisioning or application deployment.

`environment-data-operations.yml` exposes:

- `environment=prod`, `mode=selfhost_availability`, `release_tag=<release>` for read-only availability.
- `environment=prod`, `mode=core_users`, `release_tag=<release>`,
  `config_json={"source_read_only":true,"action":"compare"}` for four-field equality; compare is the default.
- `action=copy` is a separate, explicit synchronization operation. A failed receipt
  never triggers an automatic copy retry. Check target state with compare first.

Core comparison neither requires a successful prior copy/schema receipt nor
claims 53-table equality. It leaves services running; copy still guards business
writers/reconcilers while exempting exact container `web-saas-caddy`.
The availability owner checks HTTPS locally and directly from the runner to the
CMDB IP, without insecure TLS flags or changing public DNS. Missing synchronization
metrics, failed probes, empty receipts and failed child workflows fail acceptance.

Playbooks owns host/DB probes and Toolkit owns fixed-SHA dispatch, access lifecycle
and receipt validation. The checks are implemented and tested with local fixtures;
those results do not constitute live PROD acceptance.
