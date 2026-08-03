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

## Scope and target architecture

This delivery has two independent consumers of the same Xray Exporter. Vector
is the fan-out boundary; Observability is not allowed to become a hard
dependency of billing.

Billing and quota path:

```text
Xray
  -> ai-workspace-xstream/xray-exporter
  -> Vector HTTP source / fan-out
  -> Billing POST /v1/ingest/snapshots
  -> shared PostgreSQL account database
  -> Accounts GET /api/account/usage/summary
  -> Portal /panel/account
```

Realtime monitoring path:

```text
Xray
  -> ai-workspace-xstream/xray-exporter
  -> Vector Prometheus scrape
  -> Observability VictoriaMetrics remote-write
  -> Grafana Xray Dashboard
```

The retained control path is separate:

```text
Accounts
  -> agent-svc-plus
  -> generated Xray client configuration
  -> Xray reload
```

## Repository map

| Repository | Responsibility in this delivery | Current `main` evidence at handoff | Key changes |
| --- | --- | --- | --- |
| [`ai-workspace-xstream/xray-exporter`](https://github.com/ai-workspace-xstream/xray-exporter) | Fork of upstream `compassvpn/xray-exporter` v0.6.0; exposes Xray metrics, builds replayable snapshots and POSTs snapshots to Vector | `9c544eb57d82`; r6 release published | [#6](https://github.com/ai-workspace-xstream/xray-exporter/pull/6), [#12](https://github.com/ai-workspace-xstream/xray-exporter/pull/12), [#15](https://github.com/ai-workspace-xstream/xray-exporter/pull/15) |
| [`ai-workspace-services/billing-service`](https://github.com/ai-workspace-services/billing-service) | Authenticated snapshot ingest, UUID aggregation, rating, ledger/quota mutation | `e522bcc31e62` | [#24](https://github.com/ai-workspace-services/billing-service/pull/24), [#27](https://github.com/ai-workspace-services/billing-service/pull/27) |
| [`ai-workspace-services/accounts`](https://github.com/ai-workspace-services/accounts) | Shared accounting schema, quota period, account summary API and canonical account/proxy UUID | `fc65cc5d7001` | [#45](https://github.com/ai-workspace-services/accounts/pull/45), [#46](https://github.com/ai-workspace-services/accounts/pull/46), [#48](https://github.com/ai-workspace-services/accounts/pull/48) |
| [`ai-workspace-services/portal`](https://github.com/ai-workspace-services/portal) | `/panel/account` usage/quota presentation while retaining existing account functions | `5cc541b2ad34` | [#130](https://github.com/ai-workspace-services/portal/pull/130), [#131](https://github.com/ai-workspace-services/portal/pull/131), [#132](https://github.com/ai-workspace-services/portal/pull/132), [#133](https://github.com/ai-workspace-services/portal/pull/133) |
| [`x-evor/agent.svc.plus`](https://github.com/x-evor/agent.svc.plus) | Agent Proxy registration, Accounts sync and generated Xray configuration | Built on the Agent Proxy host from the requested repository ref | Existing Agent Proxy role contract |
| [`ai-workspace-infra/gitops`](https://github.com/ai-workspace-infra/gitops) | Pull-only Web SaaS compose declarations and immutable image pins | `a6b544c2f932`; UAT images pin r6 | [#131](https://github.com/ai-workspace-infra/gitops/pull/131), [#134](https://github.com/ai-workspace-infra/gitops/pull/134) |
| [`ai-workspace-infra/playbooks`](https://github.com/ai-workspace-infra/playbooks) | Native Agent Proxy, Vector, Xray, exporter, Caddy, PostgreSQL and domain-CD roles | `19112d62b9e4` after the final telemetry desired-state fix | [#223](https://github.com/ai-workspace-infra/playbooks/pull/223), [#224](https://github.com/ai-workspace-infra/playbooks/pull/224), [#225](https://github.com/ai-workspace-infra/playbooks/pull/225), [#231](https://github.com/ai-workspace-infra/playbooks/pull/231), [#232](https://github.com/ai-workspace-infra/playbooks/pull/232), [#233](https://github.com/ai-workspace-infra/playbooks/pull/233), [#235](https://github.com/ai-workspace-infra/playbooks/pull/235), [#245](https://github.com/ai-workspace-infra/playbooks/pull/245), [#246](https://github.com/ai-workspace-infra/playbooks/pull/246) |
| [`ai-workspace-infra/platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | Terraform/CMDB orchestration, four-stage workflow, cross-repository refs, UAT DNS and verification gates | `599d0b093b47` | [#244](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/244), [#247](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/247), [#255](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/255), [#256](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/256) |

The authoritative domain ownership is
[`docs/domains/DELIVERY-MANIFEST.md`](../domains/DELIVERY-MANIFEST.md):
`web-saas` owns Console, Accounts, Billing, Caddy and PostgreSQL;
`agent-proxy` owns Caddy, Xray, Exporter, Vector and agent-svc-plus.

## Version and artifact contract

| Component | UAT version |
| --- | --- |
| Cross-repository snapshot | `uat-daily-build-2026.08.03-r6` |
| Accounts image | `ghcr.io/ai-workspace-services/accounts:uat-daily-build-2026.08.03-r6` |
| Billing image | `ghcr.io/ai-workspace-services/billing-service:uat-daily-build-2026.08.03-r6` |
| Console image | `ghcr.io/ai-workspace-services/console:uat-daily-build-2026.08.03-r6` |
| Xray Exporter release | [`uat-daily-build-2026.08.03-r6`](https://github.com/ai-workspace-xstream/xray-exporter/releases/tag/uat-daily-build-2026.08.03-r6) |
| Xray Exporter binary commit | `9c544eb57d82c89017827b90222161552bd90f7e` |

The exporter release contains Linux amd64/arm/arm64, Darwin amd64/arm64 and
Windows amd64/arm64 assets. UAT must not fall back to a same-named release in
`compassvpn/xray-exporter`; that upstream repository does not publish internal
UAT snapshot tags.

## Environment map

| Item | UAT value / contract |
| --- | --- |
| Environment | `uat` |
| Source/reference domain | `svc.plus` (read-only comparison only) |
| Target base domain | `onwalk.net` |
| Delivery domains | `web-saas + agent-proxy` |
| Cloud/provider | Vultr VPS, Tokyo (`nrt`) |
| Web SaaS plan | `2C4G` / `vc2-2c-4gb` |
| Agent Proxy plan | matrix default `1C2G` / `vc2-1c-2gb` |
| CD model | GitOps pull-only for Web SaaS; native Ansible for Agent Proxy |
| Production DNS cutover | disabled (`confirm_dns_switch=false`) |
| UAT DNS reconciliation | enabled (`uat_dns_update=true`) |
| TLS | shared wildcard material restored from Vault before Caddy validation |

Rendered UAT endpoints:

| Endpoint | Role | Expected current IP |
| --- | --- | --- |
| `console-uat.onwalk.net` | Portal / Console | `167.179.110.129` |
| `accounts-uat.onwalk.net` | Accounts API | `167.179.110.129` |
| `billing-uat.onwalk.net` | Billing ingest / service ingress | `167.179.110.129` |
| `postgresql-saas-uat.onwalk.net` | PostgreSQL tunnel/service alias | `167.179.110.129` |
| `agent-proxy.onwalk.net` | Xray / Agent Proxy | `45.32.19.172` |

Workflow refs used for the final verification run:

| Input | Value |
| --- | --- |
| `deploy_tag` | `uat-daily-build-2026.08.03-r6` |
| `toolkit_ref` | `main` |
| `playbooks_ref` | `main` |
| `gitops_ref` | `main` |
| `infra_ref` | `main` |
| `console_ref` | `uat-daily-build-2026.08.03-r6` |
| `run_infrastructure` | `true` |
| `run_application_deploy` | `true` |
| `action` | `deploy` |
| `offline_mode` | `off` |

## Secrets, database and identity boundaries

Only secret locations and key contracts are recorded here; values must never be
copied into this document, GitHub Actions inputs or repository files.

| Vault path | Purpose |
| --- | --- |
| `kv/data/CICD` | Shared pull credentials and common CI values |
| `kv/data/CICD/uat` | UAT SSH, Vultr and Terraform backend credentials |
| `kv/data/uat/databases` | UAT PostgreSQL service-role passwords, including `account_pg_password`, `billing_pg_password` and `postgres_root_password` |
| `kv/data/uat/agent-proxy` | Agent Proxy UUID/runtime values |
| `kv/data/WEB_SAAS` | Existing Web SaaS runtime values still consumed by the current deployment contract |

Database invariants:

- Accounts and Billing share the `account` PostgreSQL database; do not create a
  second Billing database for this feature.
- `account_pg_password` is the canonical shared runtime credential where the
  shared-database path requires one credential.
- `account_quota_states` owns remaining quota and period boundaries.
- `traffic_minute_buckets` owns minute usage aggregation.
- `billing_ledger` owns rated accounting entries.
- `account_policy_snapshots` and `node_health_snapshots` remain part of the
  shared accounting schema bootstrap.
- Exporter fan-out must aggregate multiple nodes/inbounds by canonical user UUID
  before rating; inbound tag is not a billing identity.

Identity invariants:

- `proxy_uuid == users.uuid`.
- Portal QR UUID, Accounts UUID and Xray client UUID must remain identical.
- Email is a human-readable correlation attribute; UUID is the accounting key.
- UUID renewal/sandbox rotation must update the canonical UUID path instead of
  generating an independent proxy identity.

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

This is an ordering race, not missing implementation on `playbooks/main`:

- `[2] Monitor Agent` depends only on the generic bootstrap stage and can run
  before `[3] Agent Proxy` installs native Xray services.
- `deploy_observability_agent.yml` currently derives
  `vector_xray_exporter_enabled` from `pgrep -x xray`.
- In this run Vector was rendered and started around 18:09, while native Xray
  and exporter services started around 18:30.
- The process check was therefore false when the template rendered. Both Xray
  Prometheus sources were omitted and the later Agent Proxy job did not rerun
  the Vector role.

The generated CMDB `agent_proxy` group is the deployment intent and must be the
authoritative render-time signal. A transient process check is suitable for
deciding whether to touch an already-running legacy host, but not for deciding
the desired configuration of a newly provisioned Agent Proxy.

Permanent fix: [ai-workspace-infra/playbooks#246](https://github.com/ai-workspace-infra/playbooks/pull/246),
merged as `19112d62b9e49a93a6dd0e3e9cfb4b0d9e411d44`. It derives Vector's
desired Xray telemetry state from membership in the generated `agent_proxy`
group and retains the process check only as a compatibility fallback. The PR is
merged but was not present when run 30806223467 checked out playbooks; a later
UAT run must provide runtime evidence for it.

### Billing snapshot gap

Both exporter services logged once per minute:

```text
Vector snapshot push failed: Post "http://127.0.0.1:8686": connect: connection refused
```

Vector is active, but its current configuration does not listen for exporter
snapshot POSTs on `127.0.0.1:8686`. Therefore no snapshot can fan out to
Billing, no traffic/ledger/quota row can change, and Accounts correctly returns
zero usage to Portal.

The same ordering race suppresses the Billing HTTP source. The workflow passed
`VECTOR_BILLING_INGEST_ENABLED=true`, the `127.0.0.1:8686` address, Billing URL
and internal token, but the Vector template also gates `xray_snapshot_input` on
`vector_xray_exporter_enabled`. Because Xray was not running yet, the otherwise
valid Billing fan-out configuration was omitted.

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

## Decisions that must survive handoff

- Billing and Accounts remain in one PostgreSQL database.
- Vector is the fan-out boundary. Billing does not directly poll Exporter by
  default, and Observability is not a required hop for billing correctness.
- Existing Accounts/Xray/Portal control functions remain in place; this feature
  is additive.
- Multiple Xray nodes and multiple inbounds aggregate by canonical UUID before
  rating. Email is retained for operator correlation.
- UAT uses `onwalk.net`; production `svc.plus` hosts and DNS are outside the
  mutation scope.
- UAT TLS is restored from Vault wildcard material before Caddy verification.
- Web SaaS CD remains pull-only: GitHub Actions updates GitOps refs where
  authorized, while Doco-CD performs the actual compose reconciliation.
- Every deployable repository must publish the same immutable snapshot tag.
  Exporter is included in that contract and must not use an unrelated fixed tag.

## Read-only verification runbook

Workflow state:

```bash
gh run view 30806223467 \
  --repo ai-workspace-infra/platform-ops-toolkit \
  --json status,conclusion,jobs
```

Public DNS, avoiding the workstation's potentially stale resolver cache:

```bash
for host in \
  console-uat.onwalk.net \
  accounts-uat.onwalk.net \
  billing-uat.onwalk.net \
  agent-proxy.onwalk.net
do
  dig +short @1.1.1.1 A "$host"
done
```

Agent Proxy service and generated Vector configuration:

```bash
ssh root@45.32.19.172 \
  'systemctl is-active vector xray xray-tcp xray-exporter-xhttp xray-exporter-tcp agent-svc-plus'

ssh root@45.32.19.172 \
  'ss -lntp | grep -E ":(8080|8081|8686)\\b"'

ssh root@45.32.19.172 \
  'grep -nE "xray_xhttp_metrics|xray_tcp_metrics|xray_snapshot_input|billing_snapshot_ingest" /etc/vector/vector.toml'
```

Data-plane logs:

```bash
ssh root@45.32.19.172 \
  'journalctl -u vector -u xray-exporter-xhttp -u xray-exporter-tcp --since "10 minutes ago" --no-pager'
```

Shared accounting rows on the UAT Web SaaS host:

```bash
ssh root@167.179.110.129 \
  'docker exec web-saas-postgresql psql -U postgres -d account -c \
  "select count(*) from traffic_minute_buckets; \
   select count(*) from billing_ledger; \
   select count(*) from account_quota_states;"'
```

Do not print environment files, database URLs, Vault responses, internal tokens
or user UUID lists into CI logs or handoff documents.

## Rollback and recovery boundaries

- Application rollback: pin all Web SaaS images and the exporter release to one
  earlier complete cross-repository snapshot; do not mix tags per service.
- Playbook rollback: revert through a PR and rerun UAT with an explicit
  `playbooks_ref`; do not edit the host as the lasting source of truth.
- DNS rollback: reconcile parameterized UAT records from the CMDB of the chosen
  UAT run. Never use the production DNS switch for a UAT correction.
- Database rollback: schema changes are additive and idempotent. Do not drop the
  shared account database or rerun destructive baseline SQL against existing
  data.
- Host debugging may temporarily inspect or restart UAT services, but every
  durable correction must return to Git, PR review and a reproducible run.

## Final evidence checklist

- [x] PostgreSQL dedicated-role TCP authentication passes.
- [x] Shared Web SaaS baseline schemas initialize.
- [x] Agent Proxy native services deploy and pass the workflow verifier.
- [x] Parameterized UAT DNS records point to the CMDB hosts.
- [x] Current UAT Web SaaS endpoints complete TLS and return HTTP responses.
- [ ] Run 30806223467 completes successfully from the #256 merge commit.
- [ ] DNS Gate duration confirms the resolver-cache wait is removed.
- [x] CMDB-based Vector desired-state fix merged in playbooks #246.
- [ ] Vector scrapes exporter ports 8080/8081 and Grafana lists the UAT node.
- [ ] Exporter-to-Vector snapshot listener and Billing fan-out are verified.
- [ ] PostgreSQL, Accounts summary and Portal show non-zero UAT usage.

## Safe continuation

1. Finish run 30806223467 and record the DNS Gate duration.
2. Add Vector Prometheus scrape sources for Xray Exporter ports `8080` and
   `8081` by treating membership in the generated `agent_proxy` group as the
   desired-state signal; label them with the UAT node and transport and retain
   the existing remote-write sink.
3. Render the Vector HTTP source expected at `127.0.0.1:8686` from the same
   desired-state signal; preserve the existing observability sinks and fan out
   snapshots to Billing. Do not rely on `pgrep` during first bootstrap.
4. Verify Grafana registration and Billing ingest, then shared PostgreSQL row
   changes, Accounts summary and Portal UI.
5. Keep all mutations UAT-only. Treat `console.svc.plus` and
   `tky-proxy.svc.plus` as read-only references.
