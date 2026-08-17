# Serverless Orchestrator 矩阵部署

`.github/workflows/serverless-orchestrator.yml` 的手动执行页只保留制品版本、环境和执行开关。
UAT 是默认环境；路由、域名、Worker 名称和数据库模式统一从 GitOps 读取。

## 三种运行模式

```text
VPS mode
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
                    └── VPS primary → Cloud Run request-level fallback
```

Canonical DNS is the top-level switch. UAT uses `console-uat.onwalk.net` and
`accounts-uat.onwalk.net`; their `vps` and `serverless` CNAME targets, TTL, and desired mode are
declared in:

```text
ai-workspace-infra/gitops/resources/svc.plus/uat/cloudflare/edge-routing.yaml
```

The UAT declaration currently uses `spec.runtime.mode: hybrid`, with VPS weight 100 and
Serverless weight 0. The orchestrator does not silently mutate DNS or select a hidden fallback
mode.

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

`edge-gateway` is a required stage. VPS→Cloud Run request-level failover is enabled only when
`spec.runtime.mode` is `hybrid`; `serverless` routes directly to Cloud Run and `vps` is served by
VPS Full Stack through DNS.

## GitOps boundary contract

The workflow checks out GitOps `main`, renders the environment YAML, and passes the temporary
manifest to every Cloudflare consumer. The manifest must define:

- `spec.runtime.mode` (`vps`, `serverless`, or `hybrid`), routing, services, and data handover;
- flat `spec.domains` entries with both `vps` and `serverless` targets;
- Cloudflare zone and Pages project;
- exactly five `spec.serverless.ssr` boundaries;
- `auth`, `admin`, and `core` in `spec.serverless.edge_gateway`, with `core` owning `/api/*`;
- both database modes and a disabled async DTS reservation under `spec.runtime.data.migration`.

Repository-local Cloudflare boundary JSON is not a deployment source of truth and is not used by
the orchestrator.

## Database handover and DTS reservation

GitOps reserves both database endpoints under `spec.runtime.data`:

- VPS mode: self-managed PostgreSQL;
- Serverless mode: Supabase Cloud DB;
- async DTS: declared but disabled by default;
- one active writer only, 60-second maximum lag target, and a required quiesce window;
- connection strings and replication credentials remain in Vault and are never committed.

Before a DNS cutover, the operator must validate lag, quiesce writes, promote exactly one writer,
switch the canonical CNAME, and run Verify / Summary. Rollback reverses those steps without
overwriting or deleting DTS checkpoints.

## Manual inputs

The normal UAT dispatch is:

```text
vault_env_path=uat                 # default
tag_ref=daily-build-YYYY.MM.DD-rN  # required immutable snapshot
deploy_cloud_run=true              # default
deploy_cloudflare=true             # default
verify_supabase=true               # default
initialize_supabase=false          # default
```

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
