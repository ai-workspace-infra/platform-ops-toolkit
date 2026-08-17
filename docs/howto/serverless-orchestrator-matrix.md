# Serverless Orchestrator 矩阵部署

`.github/workflows/serverless-orchestrator.yml` 的手动执行页只保留制品版本、环境和执行开关。
UAT 是默认环境；路由、域名、Worker 名称和数据库模式统一从 GitOps 读取。

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

Canonical DNS is the top-level switch. UAT uses `console-uat.onwalk.net` and
`accounts-uat.onwalk.net`; their `selfhost` and `serverless` CNAME targets, TTL, and desired mode
are
declared in:

```text
ai-workspace-infra/gitops/topology/uat/serverless/runtime-topology.yaml
```

The serverless workflow requires the serverless pre-configuration at
`spec.runtime.mode: serverless`. The hybrid workflow independently uses the hybrid pre-configuration
with selfhost weight 100 and Serverless weight 0; the hybrid
workflow owns the request-level selfhost→Cloud Run failover.

## Deployment stages and dependencies

Deployment order is intentionally separate from request topology:

```text
Supabase / xworktech
        │
        ▼
Cloud Run / accounts, content-service, billing-service
        │
        ▼
Cloudflare / SSR / public, content, auth, console, workspace
        │
        ▼
edge-gateway / auth, admin, core
        │
        ▼
Cloudflare Pages / static assets
        │
        ▼
Verify / Summary
```

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
| API auth | `edge-gateway-auth-uat` | `accounts-cloudflare-uat.onwalk.net/api/auth/*` |
| API admin | `edge-gateway-admin-uat` | `accounts-cloudflare-uat.onwalk.net/api/admin/*` |
| API core | `edge-gateway-core-uat` | `accounts-cloudflare-uat.onwalk.net/api/*` fallback |
| Static assets | `ai-workspace-portal-uat` | `/static/*`, `/assets/*` |

## GitOps boundary contract

The workflow checks out GitOps `main`, renders the environment YAML, and passes the temporary
manifest to every Cloudflare consumer. The manifest must define:

- `spec.runtime.mode` (`selfhost`, `serverless`, or `hybrid`), routing, services, and data handover;
- flat `spec.domains` entries with both `selfhost` and `serverless` targets;
- Cloudflare zone and Pages project;
- exactly five `spec.serverless.ssr` boundaries;
- `auth`, `admin`, and `core` in `spec.serverless.edge_gateway`, with `core` owning `/api/*`;
- both database modes and an async DTS reservation under `spec.runtime.data.migration`.

Repository-local Cloudflare boundary JSON is not a deployment source of truth and is not used by
the orchestrator.

## Database handover and DTS reservation

GitOps reserves both database endpoints under `spec.runtime.data`:

- Selfhost mode: self-managed PostgreSQL;
- Serverless mode: Supabase Cloud DB;
- async DTS: declared but disabled by default;
- one active writer only, 60-second maximum lag target, and a required quiesce window;
- connection strings and replication credentials remain in Vault and are never committed.

Before a DNS cutover, the operator must validate lag, quiesce writes, promote exactly one writer,
switch the canonical CNAME, and run Verify / Summary. Rollback reverses those steps without
overwriting or deleting DTS checkpoints.

## Manual inputs

The manual dispatch uses one explicit operation:

```text
operation=plan             # only validate GitOps and dispatch inputs
operation=saas             # initialize Supabase only
operation=deploy           # deploy the selected serverless application targets
operation=migrate          # migrate VPS PostgreSQL data to Supabase
operation=deploy+migrate  # deploy first, then migrate
operation=destroy          # destroy environment-scoped ephemeral Cloud Run compute
```

For an application deployment, the normal UAT dispatch is:

```text
vault_env_path=uat                 # default
tag_ref=daily-build-YYYY.MM.DD-rN  # required immutable snapshot
deploy_cloud_run=true              # default
deploy_cloudflare=true             # default
```

`tag_ref` is required only for `deploy` and `deploy+migrate`. The `operation` input is the
control-plane authority that selects whether the migration job runs. GitOps declares the data
topology and migration capability (`spec.runtime.data.migration.enabled`) but does not authorize
or select an individual workflow run.

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
