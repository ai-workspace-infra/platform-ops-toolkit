# Serverless Orchestrator 矩阵部署

`.github/workflows/serverless-orchestrator.yml` 的手动执行页现在按组件显示独立任务。

## 任务与依赖

```text
Supabase / xworktech
        │
        ▼
Cloud Run / accounts, content-service, billing-service
        │
        ▼
Cloudflare / SSR（多个）
        │
        ▼
edge-gateway / auth, admin, core（必选）
        │
        ▼
Cloudflare / static-pages
        │
        ▼
Verify / Summary
```

任务依赖按从左到右排列为：
`Supabase → Cloud Run → Cloudflare SSR → edge-gateway → static-pages → Verify / Summary`。
`edge-gateway` 不再是可选 job，必须成功后才发布静态 Pages 资源。

## Cloudflare UAT 边界

边界清单位于 `.github/serverless/cloudflare-boundaries.json`：

| 层 | Worker / Pages | 路径边界 | 当前状态 |
|---|---|---|---|
| SSR 公共页面 | `frontend-ssr-public-uat` | `/*`、`/_edge/public/*` | 独立轻量 Worker |
| SSR 内容页面 | `frontend-ssr-content-uat` | `/blogs*`、`/docs*`、`/download*` | 独立轻量 Worker |
| SSR 身份页面 | `frontend-ssr-auth-uat` | `/login*`、`/register*` 等 | 独立轻量 Worker |
| SSR 控制台 | `frontend-ssr-console-uat` | `/panel*`、`/dashboard*` | 独立轻量 Worker |
| SSR 工作区 | `frontend-ssr-workspace-uat` | `/ai-workspace*`、`/editor*` 等 | 独立轻量 Worker |
| API 鉴权 | `edge-gateway-auth-uat` | `accounts-cloudflare-uat.onwalk.net/api/auth/*` | 独立轻量 Worker |
| API 管理 | `edge-gateway-admin-uat` | `accounts-cloudflare-uat.onwalk.net/api/admin/*` | 独立轻量 Worker |
| API 核心 | `edge-gateway-core-uat` | `accounts-cloudflare-uat.onwalk.net/api/*` 兜底 | 独立轻量 Worker |
| 静态资源 | `ai-workspace-portal-uat` | `/static/*`、`/assets/*` | Pages 部署 |

这里的拆分是源代码级拆分：不能仅复制 `wrangler` 名称，否则每个 Worker 仍会打包整套
OpenNext 应用，无法解决 Cloudflare Worker 3 MiB 限制。API 三个独立入口已经在
`ai-workspace-services/edge-gateway` 中提供；Worker 名称、API 主机和路径由该仓库的
`config/edge-gateway-boundaries.json` 配置，部署脚本据此创建三个独立 Worker 和 Routes。

## 输入建议

UAT 常用值：

```text
vault_env_path=uat
tag_ref=<不可变 daily-build-* 快照>
deploy_cloudflare=true
deploy_cloud_run=true
verify_supabase=true
```

`tag_ref` 是 Cloud Run 镜像、Portal 源码和 edge-gateway 源码的唯一版本输入。任务会使用同一
个不可变 tag 检出 Portal 和 edge-gateway，并将同名 tag 传给三个 Cloud Run 镜像；本地开发机
路径不会被带入 CI。Portal、edge-gateway 和 GitOps 仓库是固定的平台交付依赖，不在手动派发
页面重复暴露。

GitOps 路由配置固定从 `main` 读取。它是环境配置源，不属于应用制品 tag；这样不会因为某个
服务快照 tag 尚未同步到 GitOps 仓库而导致路由配置 checkout 失败。

## Cloud Run 镜像契约

每个矩阵项只部署一个服务：

```text
<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/serverless/accounts:<tag_ref>
<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/serverless/content-service:<tag_ref>
<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/serverless/billing-service:<tag_ref>
```

因此，执行完整部署前必须先在 `xworktech` 项目的 Artifact Registry 中创建
`serverless` 仓库，并确保三个镜像已经以相同的不可变快照 tag 推送。没有镜像时，矩阵会
分别显示三个 Cloud Run 任务失败，便于定位，而不是把三个服务合并成一个失败步骤。

## 凭据来源

所有任务继续使用 GitHub OIDC → Vault JWT。Cloud Run 的 GCP provider、服务账号和项目
配置从 `kv/uat/serverless/gcp` 读取；Cloudflare 凭据从
`kv/uat/serverless/cloudflare` 读取；Supabase 连接契约从
`kv/uat/serverless/supabase` 读取。不生成或上传 JSON 私钥。
