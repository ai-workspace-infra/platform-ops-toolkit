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
Cloudflare / dashboard (Pages), edge-worker（可选）, edge-gateway（可选）
        │
        ▼
Verify / Summary
```

任务依赖按从左到右排列为 `Supabase → Cloud Run → Cloudflare → Verify / Summary`。
Cloudflare 前端部署以 `dashboard`（Cloudflare Pages 静态控制台）为主发布路径，部署前自动创建 Pages 项目（`ai-workspace-portal-<env>`）；
`edge-worker`（portal OpenNext Worker）与 `edge-gateway` 为独立可选 job，默认 skipped。Verify job 会校验 Supabase 连接契约，并把
各阶段结果写入 GitHub Step Summary。

## 输入建议

UAT 常用值：

```text
vault_env_path=uat
image_tag=<不可变 daily-build-* 快照>
deploy_cloudflare=true
deploy_edge_worker=false
deploy_edge_gateway=false
deploy_cloud_run=true
verify_supabase=true
```

- `deploy_cloudflare=true` 会构建并发布 portal 的静态控制台到 Cloudflare Pages。
- `deploy_edge_worker=true` 时，会执行 OpenNext 完整服务端 Worker 发布（依赖 Cloudflare 付费套餐规格支持大体积 Worker）。
- `deploy_edge_gateway=true` 时，还需要填写可被 GitHub Actions 访问的
`edge_gateway_repository` 和 `edge_gateway_ref`。该任务会检出 edge-gateway 仓库，执行
Cloudflare Worker 发布；本地开发机路径不会被带入 CI。

## Cloud Run 镜像契约

每个矩阵项只部署一个服务：

```text
<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/serverless/accounts:<image_tag>
<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/serverless/content-service:<image_tag>
<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/serverless/billing-service:<image_tag>
```

因此，执行完整部署前必须先在 `xworktech` 项目的 Artifact Registry 中创建
`serverless` 仓库，并确保三个镜像已经以相同的不可变快照 tag 推送。没有镜像时，矩阵会
分别显示三个 Cloud Run 任务失败，便于定位，而不是把三个服务合并成一个失败步骤。

## 凭据来源

所有任务继续使用 GitHub OIDC → Vault JWT。Cloud Run 的 GCP provider、服务账号和项目
配置从 `kv/uat/serverless/gcp` 读取；Cloudflare 凭据从
`kv/uat/serverless/cloudflare` 读取；Supabase 连接契约从
`kv/uat/serverless/supabase` 读取。不生成或上传 JSON 私钥。
