# Serverless Orchestrator 矩阵部署

`.github/workflows/serverless-orchestrator.yml` 的手动执行页提供制品版本、环境、执行开关，
以及与 Selfhost 编排器一致的业务域和云服务商选择。UAT 是默认环境；路由、域名、Worker
名称和数据库模式统一从 GitOps 读取。

## 三种运行模式

```text
Selfhost mode
DNS → VPS Full Stack
    ├── Console
    ├── Accounts
    ├── Content
    ├── Billing
    └── self-managed PostgreSQL

Serverless mode
DNS → Cloudflare Pages
    └── SSR ×5
        └── edge-gateway ×3: auth / admin / core
            └── Cloud Run: accounts / content-service / billing-service
                └── Supabase Cloud DB

Hybrid mode
DNS → Cloudflare edge → edge-gateway
                    └── selfhost primary → Cloud Run request-level fallback
```

Canonical DNS is an explicit traffic cutover switch, not a side effect of every deployment. UAT
uses `console-uat.onwalk.net` and `accounts-uat.onwalk.net`; their `selfhost` and `serverless`
targets, TTL, and desired mode are declared in:

```text
ai-workspace-infra/gitops/topology/uat/serverless/runtime-topology.yaml
```

Every mode profile also declares the five public service entrances in
`spec.public_endpoints` using `<service>-<mode>-<environment>.<base-domain>`:

| Service | Default access | Serverless UAT | Selfhost UAT |
| --- | --- | --- | --- |
| Console | public | `console-serverless-uat.onwalk.net` | `console-selfhost-uat.onwalk.net` |
| Accounts | authenticated | `accounts-serverless-uat.onwalk.net` | `accounts-selfhost-uat.onwalk.net` |
| Billing | authenticated | `billing-serverless-uat.onwalk.net` | `billing-selfhost-uat.onwalk.net` |
| PostgreSQL | authenticated | `postgresql-serverless-uat.onwalk.net` | `postgresql-selfhost-uat.onwalk.net` |
| Agent-Proxy | public UUID validation | `agent-proxy-serverless-uat.onwalk.net` | `agent-proxy-vps-uat.onwalk.net` |

The Serverless workflow actively reconciles and verifies Console, Accounts, and Billing. PostgreSQL
and Agent-Proxy keep provider-owned authenticated/UUID validation paths until their deployment
provider exposes an equivalent adapter.

The mode-qualified entries can coexist as separate DNS names. A normal Serverless deployment uses
`dns_mode=none`, publishes only the `*-serverless-uat` entries, and verifies those entries directly;
it does not rewrite `console-uat.onwalk.net` or `accounts-uat.onwalk.net`. The Serverless workflow
may change the canonical aliases only with the explicit `dns_mode=uat-records` or
`dns_mode=prod-cutover` input. Selfhost uses the same DNS choices. The two DNS jobs
share the `public-dns-<environment>` concurrency group, so only one public cutover can run at a
time. Distinct hostnames may each have a CNAME; the same hostname cannot have two CNAME targets or
weighted DNS behavior on the free DNS tier.

The serverless workflow requires the serverless pre-configuration at
`spec.runtime.mode: serverless`. The hybrid workflow independently uses the hybrid pre-configuration
with selfhost weight 100 and Serverless weight 0; the hybrid
workflow owns the request-level selfhost→Cloud Run failover.

### Billing Cloud Run routing

`billing-serverless-<environment>` is a custom domain of the core Edge Gateway Worker. The
Worker proxies Billing requests to the GitOps-declared Cloud Run `run.app` upstream and preserves
the public host separately. This avoids Cloudflare Origin Rule Host/SNI overrides, which require
an Enterprise plan. `billing_origin_host` is a retired compatibility field; reconciliation removes
its old DNS-only CNAME when present and does not create or update an Origin Ruleset.

## Deployment stages and dependencies

Deployment order is intentionally separate from request topology. The application targets run in
parallel after preflight, then readiness is the single fan-in:

```text
                         preflight
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
      Supabase       Cloud Run       Cloudflare
                                      SSR / Router /
                                      Gateway / Pages
             └──────────────┼──────────────┘
                            ▼
                  Readiness / public chain
                            ▼
                    Migrate (if selected)
                            ▼
                      Verify / Summary
```

Supabase, Cloud Run, SSR, Frontend Router, Edge Gateway, and Pages depend only on `preflight` and
run in parallel. Migration runs after readiness and is serialized by the shared data-migration
concurrency group for the environment and migration scope.

`edge-gateway` is a required stage. selfhost→Cloud Run request-level failover is enabled only
when `spec.runtime.mode` is `hybrid`; `serverless` routes directly to Cloud Run and `selfhost` is
served by the VPS Full Stack through DNS.

The five SSR Workers, three edge-gateway Workers, and Pages project remain separate deployment
units because the Cloudflare Worker artifact must stay below 3 MiB. The GitOps manifest is the
source of truth for these names and routes:

| Boundary | Name | Route contract |
| --- | --- | --- |
| SSR public | `frontend-ssr-public-uat` | `/*`, `/_edge/public/*` |
| SSR content | `frontend-ssr-content-uat` | `/blogs*`, `/docs*`, `/download*` |
| SSR identity | `frontend-ssr-auth-uat` | `/login*`, `/register*`, etc. |
| SSR console | `frontend-ssr-console-uat` | `/panel*`, `/dashboard*` |
| SSR workspace | `frontend-ssr-workspace-uat` | `/ai-workspace*`, `/editor*`, etc. |
| API auth | `edge-gateway-auth-uat` | `accounts-serverless-uat.onwalk.net/api/auth/*` |
| API admin | `edge-gateway-admin-uat` | `accounts-serverless-uat.onwalk.net/api/admin/*` |
| API core | `edge-gateway-core-uat` | `accounts-serverless-uat.onwalk.net/api/*` fallback |
| Billing | `edge-gateway-core-uat` | `billing-serverless-uat.onwalk.net/*` custom domain |
| Static assets | `ai-workspace-portal-uat` | `/static/*`, `/assets/*` |

Console is owned only by the `frontend-router` custom domain. SSR boundaries are Service Bindings,
not public Worker Routes. Reconciliation deletes explicit routes on the GitOps Console host because
they take precedence over the custom domain and bypass the router.

## GitOps boundary contract

The workflow checks out GitOps `main`, renders the environment YAML, and passes the temporary
manifest to every Cloudflare consumer. The manifest must define:

- `spec.runtime.mode` (`selfhost`, `serverless`, or `hybrid`), routing, services, and data handover;
- flat `spec.domains` entries with both `selfhost` and `serverless` targets;
- Cloudflare zone and Pages project;
- `spec.serverless.billing_host` and the core Edge Gateway Billing upstream;
- exactly five `spec.serverless.ssr` boundaries;
- `auth`, `admin`, and `core` in `spec.serverless.edge_gateway`, with `core` owning `/api/*`;
- both database modes and an async DTS reservation under `spec.runtime.data.migration`.

Repository-local Cloudflare boundary JSON is not a deployment source of truth and is not used by
the orchestrator.

Preflight also compares Portal's UAT `dashboardUrl`, `authUrl`, and `apiBaseUrl` with these GitOps
hosts. Readiness requires `X-Frontend-Route` on public and console HTML and CSS, validates the public
Tailwind marker, and reports both boundary CSS SHA-256 hashes; HTTP 200 and file size alone are not
accepted as proof of a correct deployment.

## Database handover and DTS reservation

GitOps reserves both database endpoints under `spec.runtime.data`:

- Selfhost mode: self-managed PostgreSQL;
- Serverless mode: Supabase Cloud DB;
- async DTS: declared as a migration constraint; each run's `operation` selects execution;
- one active writer only, 60-second maximum lag target, and a required quiesce window;
- connection strings and replication credentials remain in Vault and are never committed.

Before a DNS cutover, the operator must validate lag, quiesce writes, promote exactly one writer,
switch the canonical CNAME, and run Verify / Summary. Rollback reverses those steps without
overwriting or deleting DTS checkpoints. DNS cutover is controlled by the workflow input, not by
the GitOps topology alone.

## Manual inputs

The manual dispatch uses one explicit operation:

```text
operation=plan             # only validate GitOps and dispatch inputs
operation=init-schema      # initialize and verify the Supabase Accounts schema only
operation=deploy           # deploy the selected serverless application targets
operation=migrate          # migrate VPS PostgreSQL data to Supabase
operation=deploy+migrate  # deploy first, then migrate
operation=destroy          # destroy environment-scoped ephemeral Cloud Run compute
```

For an application deployment, the normal UAT dispatch is:

```text
vault_env_path=uat                 # default
target_domains=all                 # default; equivalent to the full web-saas control plane
cloud_provider=vultr-vps           # default; the VPS replica/migration path currently supports only Vultr
tag_ref=daily-build-YYYY.MM.DD-rN  # required immutable snapshot
deploy_cloud_run=true              # default
deploy_cloudflare=true             # default
dns_mode=none                      # default; use uat-records or prod-cutover only for an intentional switch
```

The Serverless workflow only deploys the complete `web-saas` control plane
(Cloudflare, Cloud Run, and Supabase). `target_domains=web-saas` selects that segment directly;
`target_domains=all` keeps the full-domain form compatible and resolves its Serverless segment
to `web-saas`. Other domains are not deployed by this workflow; they use the
`cloud_provider` environment-replica path. Multi-cloud choices are visible for compatibility
but are rejected until their replica path is connected. `vultr-vps` is the only accepted value
today.

`dns_mode=none` is the safe default. `dns_mode=uat-records` is valid only for SIT/UAT, and
`dns_mode=prod-cutover` is valid only for production. Both cutover modes are accepted only with
`operation=deploy` or `operation=deploy+migrate` and `deploy_cloudflare=true`; they are the only
Serverless paths that change the shared canonical Console/Accounts records.

`tag_ref` is required only for `deploy` and `deploy+migrate`. The `operation` input is the
control-plane authority that selects whether the migration job runs. GitOps declares data
topology and migration constraints (strategy, single-writer, lag, and quiesce requirements), but
does not authorize or select an individual workflow run.

Supabase account-schema initialization uses the same manual workflow with
`operation=init-schema`. It is a separate job from application deployment, so it only runs the
schema initialization and verification path.

`tag_ref` is the single immutable version for Cloud Run images, Portal SSR, and edge-gateway.
The three repositories and the GitOps repository are fixed workflow dependencies, so their
repository/ref fields are intentionally not exposed as dispatch inputs.

## Credentials and artifacts

All runtime credentials use GitHub OIDC → Vault JWT:

- GCP provider and service account: `kv/uat/serverless/gcp`;
- Cloudflare account and API token: `kv/uat/serverless/cloudflare`;
- Supabase connection contract: `kv/uat/serverless/supabase`.

No JSON service-account private key is generated or uploaded. Cloud Run expects three immutable
images in `asia-northeast1-docker.pkg.dev/xworktech/serverless/` with the same snapshot tag.
