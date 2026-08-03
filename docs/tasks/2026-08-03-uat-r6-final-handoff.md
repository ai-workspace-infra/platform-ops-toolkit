# UAT r6 deployment and pipeline handoff

Date: 2026-08-03  
Environment: UAT only  
Snapshot: `uat-daily-build-2026.08.03-r6`

## Outcome

The two failures exposed by the original deployment run have been fixed on the
default branches and verified against the current UAT resources:

1. Web SaaS PostgreSQL role creation and dedicated-role TCP authentication now
   complete successfully.
2. Agent Proxy deployment now resolves the UAT exporter release from
   `ai-workspace-xstream/xray-exporter`, and the native Xray, exporter and agent
   services pass the workflow verifier.
3. UAT DNS reconciliation renders Web SaaS and Agent Proxy records from CMDB.
   Post-reconcile endpoint observation is now pinned to the CMDB Web SaaS IP so
   runner-side recursive DNS caching cannot consume a five-minute retry window.

Production hosts and `svc.plus` DNS were not modified. Production was used only
as read-only reference material during earlier analysis.

## Runs

| Run | Commit / purpose | Result |
| --- | --- | --- |
| [30785772759](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30785772759) | Original r6 deployment | Failed at DB role initialization and later Agent Proxy deployment |
| [30804736017](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30804736017) | Verify DB and Agent Proxy fixes | DB Init, Web SaaS, Monitor Agents, Observe and Agent Proxy passed; UAT DNS observation also passed after waiting for resolver cache expiry |
| [30806223467](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30806223467) | Verify DNS observation pin from current `main` | In progress at the time this handoff was first written; update the final evidence section when complete |

## Root causes and fixes

### 1. Dedicated PostgreSQL role TCP authentication

The Docker command used by `Verify dedicated role TCP authentication` supplied
`PGPASSWORD` with `-e` but omitted `-e` before `PGCONNECT_TIMEOUT=5`. Docker
therefore interpreted `PGCONNECT_TIMEOUT=5` as the container name. Every role
verification failed even though the Vault password mapping and PostgreSQL roles
were valid.

Fix: [ai-workspace-infra/playbooks#245](https://github.com/ai-workspace-infra/playbooks/pull/245)

Verification evidence:

- `Create Web SaaS databases and roles` passed in run 30804736017.
- `[2] DB Init | console-uat.onwalk.net` passed, including baseline schema
  initialization.
- The database credentials remain sourced from `kv/data/uat/databases`; secrets
  were not copied into GitHub Actions inputs or repository files.

### 2. UAT exporter release and Agent Proxy DNS routing

The UAT workflow previously fell back to the upstream `compassvpn/xray-exporter`
release location while requesting an internal UAT snapshot tag. That release did
not exist upstream. Agent Proxy DNS could also be rendered to the Web SaaS host
instead of the dedicated Agent Proxy host.

Fix: [ai-workspace-infra/platform-ops-toolkit#255](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/255)

The UAT defaults now derive:

- exporter repository: `ai-workspace-xstream/xray-exporter`
- exporter version: the selected cross-repository snapshot tag
- `agent-proxy.<target_domain_base>`: the CMDB `agent_proxy` host IP
- `billing-*`, `accounts-*`, `console-*`: the CMDB `web_saas` host IP

### 3. Slow post-reconcile DNS observation

Cloudflare reconciliation succeeded, but the GitHub runner could continue using
its previous recursive DNS answer until TTL expiry. In run 30804736017 the DNS
observation step spent about five minutes waiting even though public resolvers
already returned the new records and direct probes to the current Web SaaS IP
were healthy.

Fix: [ai-workspace-infra/platform-ops-toolkit#256](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/256)

The reconciler now exports `web_saas_ip` only after Cloudflare reconciliation
succeeds. The observer consumes it as `OBSERVE_RESOLVE_IP`, preserving TLS SNI
and HTTP health checks while bypassing stale recursive DNS caches.

## Current UAT inventory

Authoritative source: CMDB artifact from run 30804736017.

| Role | FQDN | IP | Plan |
| --- | --- | --- | --- |
| Web SaaS / PostgreSQL | `console-uat.onwalk.net` | `167.179.110.129` | `vc2-2c-4gb` |
| Agent Proxy | `agent-proxy.onwalk.net` | `45.32.19.172` | `vc2-1c-2gb` |

The older addresses `167.179.105.137` and `167.179.64.91` are not part of this
CMDB artifact and must not be used as evidence for the current deployment.

Public resolver evidence after reconciliation:

- `console-uat.onwalk.net`, `accounts-uat.onwalk.net`, and
  `billing-uat.onwalk.net` resolve to `167.179.110.129`.
- `agent-proxy.onwalk.net` resolves to `45.32.19.172`.

## Runtime evidence

On Agent Proxy `45.32.19.172`:

- `agent-svc-plus`, `xray`, `xray-tcp`, `xray-exporter-xhttp`,
  `xray-exporter-tcp`, and `vector` are active.
- Exporter version is
  `uat-daily-build-2026.08.03-r6-9c544eb57d82c89017827b90222161552bd90f7e`.
- Exporter arguments include `-u -p /var/log/xray/access.log`, distinct XHTTP/TCP
  node IDs, and separate snapshot stores.

On Web SaaS `167.179.110.129`:

- PostgreSQL and both stunnel containers are healthy.
- Accounts, Billing, Console, Caddy, and Doco-CD containers are running.
- Direct endpoint probes pinned to the current Web SaaS IP returned:
  - Console: HTTP 200
  - Accounts root: HTTP 404
  - Billing root: HTTP 403

All three codes are accepted by the delivery observer because they prove a
completed TLS handshake and a live HTTP application response.

## Open chain-level item

Pipeline success is not yet equivalent to end-to-end billing telemetry success.
At approximately 18:42 CST, the user-visible UAT state was:

- Grafana `Xray Dashboard` did not list `agent-proxy.onwalk.net` in its Node
  variable; only existing production/reference nodes were visible.
- `https://console-uat.onwalk.net/panel/account` still displayed authoritative
  usage `0 B`, quota `0 B`, no period boundary, and no policy/sync data.

Online inspection explains both symptoms.

### Realtime monitoring gap

`/etc/vector/vector.toml` on Agent Proxy currently defines only:

- `internal_metrics`
- `node_metrics` from `127.0.0.1:9100`
- `process_metrics` from `127.0.0.1:9256`

The remote-write sink receives only those three inputs. There are no Vector
Prometheus scrape sources for Xray Exporter ports `8080` and `8081`, so exporter
series and their `instance`/node labels never reach Observability/Grafana.

### Billing snapshot gap

Both exporter services logged once per minute:

```text
Vector snapshot push failed: Post "http://127.0.0.1:8686": connect: connection refused
```

Vector is active, but its current configuration does not listen for exporter
snapshot POSTs on `127.0.0.1:8686`. Therefore no snapshot can fan out to
Billing, no traffic/ledger/quota row can change, and Accounts correctly returns
zero usage to Portal.

The current workflow verifier proves only that systemd services are active. It
does not yet prove either data plane. The next chain fix must add both Vector
paths and then verify in order:

```text
Exporter accepted by Vector
  -> Billing ingest accepted
  -> PostgreSQL traffic / ledger / quota rows changed
  -> Accounts usage summary changed
  -> Portal account panel displayed non-zero usage
```

Do not declare the Xray billing chain complete from a green infrastructure
workflow alone.

## Final evidence checklist

- [x] PostgreSQL dedicated-role TCP authentication passes.
- [x] Shared Web SaaS baseline schemas initialize.
- [x] Agent Proxy native services deploy and pass the workflow verifier.
- [x] Parameterized UAT DNS records point to the CMDB hosts.
- [x] Current UAT Web SaaS endpoints complete TLS and return HTTP responses.
- [ ] Run 30806223467 completes successfully from the #256 merge commit.
- [ ] DNS Gate duration confirms the resolver-cache wait is removed.
- [ ] Vector scrapes exporter ports 8080/8081 and Grafana lists the UAT node.
- [ ] Exporter-to-Vector snapshot listener and Billing fan-out are verified.
- [ ] PostgreSQL, Accounts summary and Portal show non-zero UAT usage.

## Safe continuation

1. Finish run 30806223467 and record the DNS Gate duration.
2. Add Vector Prometheus scrape sources for Xray Exporter ports `8080` and
   `8081`, label them with the UAT node and transport, and retain the existing
   remote-write sink.
3. Add or enable the Vector HTTP source expected at `127.0.0.1:8686`; preserve
   the existing observability sinks and fan out snapshots to Billing.
4. Verify Grafana registration and Billing ingest, then shared PostgreSQL row
   changes, Accounts summary and Portal UI.
5. Keep all mutations UAT-only. Treat `console.svc.plus` and
   `tky-proxy.svc.plus` as read-only references.
