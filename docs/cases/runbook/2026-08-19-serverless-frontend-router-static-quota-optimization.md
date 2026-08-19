# 架构案例：Serverless 前端静态资产穿透 Frontend Router 额度优化与多环境 CDN 契约落地

## TL;DR

在 Serverless 全栈边缘架构中，将入口域名绑定至 Cloudflare `Frontend Router` (Worker) 能提供清晰的统一流量调度与 Service Binding 分发能力。然而，在默认配置下，单页面加载伴随的 20~50 个静态资产请求（`/_next/static/*`、`/static/*`、JS chunks、CSS、图片、字体）会**全量穿透 Frontend Router Worker**，导致每日 10 万次 Worker 免费请求配额在极少次页面访问（约 2,000 ~ 3,000 次 PV）后即被耗尽。

通过引入 **Next.js `assetPrefix` + GitOps 多环境混合静态 CDN 契约**，将静态资源流量 100% 旁路直连 Cloudflare Pages 全球 CDN，消除 Worker 级联代理开销，使每日 10 万次配额的真实业务承载能力提升 **30~50 倍**，同时对本地开发与 VPS 自建 (Selfhost) 运行时保持 100% 向后兼容。

---

## 1. 问题背景与损耗根源剖析

### 1.1 初始架构拓扑与链路瓶颈
在初始设计中，`console-cloudflare-uat.onwalk.net` 作为 Worker Custom Domain 绑定至 `frontend-router-uat`：

```text
[ 用户端请求 ] ──► [ Cloudflare Edge (DNS / WAF) ] ──► [ Frontend Router (Worker) ]
                                                                 │
                                       ┌─────────────────────────┼─────────────────────────┐
                                       ▼                         ▼                         ▼
                                5 SSR Workers             fetch(Pages Origin)        3 Edge Gateway
                              (Service Binding)           (子请求代理静态资源)         (API 独立入口)
```

### 1.2 损耗放大机理 (Threefold Amplification)
1. **全量静态资产穿透 Worker (Worker Invocation Burn)**：
   Worker Custom Domain 在 DNS 顶层拦截所有流量 (`/*`)。浏览器加载单个页面所发起的 HTML、JS chunk、CSS、SVG、WebP 甚至 `favicon.ico`，每一个 HTTP 请求都会触发一次 Worker 调度（计入 1 次 Invocation）。
2. **多层 Worker 级联与子请求 (Double Invocations & Subrequests)**：
   `frontend-router` 接收到静态路径后，在 `src/index.ts` 中通过 `fetch(requestForOrigin(..., env.PAGES_ORIGIN))` 发起子请求向 Pages 回源，增加了边缘延迟与连接开销。
3. **Cloudflare Pages 免额度特性被短路**：
   Cloudflare Pages 原生具备无限免费请求与全球 CDN 缓存特性。但因域名直接绑定在 Worker 上，静态流量无法在 DNS 层被 Pages 免费拦截响应。

---

## 2. 多环境混合静态 CDN 契约落地一览

为了在开发测试敏捷性与生产规范性之间取得最佳平衡，采用 **SIT/UAT Pages 原生直连 + PROD 自定义资产域名** 的混合落地契约：

```text
                      ┌───────────────────────────────────────────────┐
                      │    GitOps: spec.cloudflare.static_cdn_url     │
                      └──────────────────────┬────────────────────────┘
                                             │
             ┌───────────────────────────────┼───────────────────────────────┐
             ▼                               ▼                               ▼
      【SIT 环境】                    【UAT 环境】                    【PROD 生产环境】
   (模式 A: Pages 原生)            (模式 A: Pages 原生)            (模式 B: 自定义资产域名)
https://ai-workspace-portal-    https://ai-workspace-portal-          https://assets.svc.plus
       sit.pages.dev                   uat.pages.dev                             │
             │                               │                                   ▼
             ▼                               ▼                       Cloudflare Pages Custom Domain
    [零配置/零证书成本]              [零配置/零证书成本]                [品牌域名统一，免 Worker 消耗]
```

### 2.1 各环境契约矩阵

| 环境 (Environment) | 接入模式 | GitOps 声明 (`static_cdn_url`) | 资产服务终端 | 运维与证书特征 |
| :--- | :--- | :--- | :--- | :--- |
| **SIT** | 模式 A：Pages 原生免费域名 | `https://ai-workspace-portal-sit.pages.dev` | Cloudflare Pages CDN | 零 DNS 维护，自带 HTTPS 证书与 Anycast CDN |
| **UAT** | 模式 A：Pages 原生免费域名 | `https://ai-workspace-portal-uat.pages.dev` | Cloudflare Pages CDN | 零配置即配即用，彻底解除测试限流 |
| **PROD** | 模式 B：自定义资产 CNAME 域名 | `https://assets.svc.plus` | Pages Custom Domain | 品牌统一规范，生产级资产域名分离 |

---

## 3. 改造收益与兼容性保障

### 3.1 改造收益
- **Worker 额度节省率达 95% ~ 98%**：单次完整页面加载从消耗 30~50 次 Worker 请求降低为**仅消耗 1 次**（仅 HTML SSR 渲染）。
- **请求承载上限倍增**：每日 10 万次免费配额从原本仅能支撑 ~2,000 次 PV，提升至可稳定支撑 **50,000 ~ 80,000 次真实页面访问**。
- **页面首屏加载时延降低**：静态资源由 Cloudflare Pages CDN 节点就近直出，消除 Worker CPU 执行与子请求代理带来的额外耗时。

### 3.2 兼容性保障与平滑兜底
1. **VPS 自建模式 (Selfhost Runtime) 零破坏**：
   当 `NEXT_PUBLIC_STATIC_CDN_URL` 环境变量未设置时（本地 `next dev`、Docker 容器单机运行、`selfhost-orchestrator.yml` 交付链路），`assetPrefix` 保持为 `undefined`，完全维持原有相对路径（`/_next/static/...`）与本地 Caddy/Docker 静态挂载逻辑。
2. **Frontend Router 优雅兜底 (Graceful Fallback)**：
   `frontend-router` 内部的 `isStaticAsset` 与 `route === 'static'` 逻辑完全保留，作为安全兜底网，若有极少数历史脚本或直接敲根域名的静态请求（如 `/favicon.ico`, `/robots.txt`），依然能被正确转发。

---

## 4. 跨仓库落地实现清单与关联 PR

本方案通过三端协同、极小代码侵入完成交付：

```text
ai-workspace-services/portal (PR #242)
  ├── next.config.mjs                    ── assetPrefix: staticCdnUrl || undefined
  ├── static-dashboard/next.config.mjs   ── assetPrefix: staticCdnUrl || undefined
  └── scripts/build-open-next-boundary   ── 拼接 ${staticCdnUrl}/_edge/${boundary}

ai-workspace-infra/gitops (PR #169)
  ├── topology/sit/serverless/runtime-topology.yaml   ── static_cdn_url: https://ai-workspace-portal-sit.pages.dev
  ├── topology/uat/serverless/runtime-topology.yaml   ── static_cdn_url: https://ai-workspace-portal-uat.pages.dev
  ├── topology/prod/serverless/runtime-topology.yaml  ── static_cdn_url: https://assets.svc.plus
  └── docs/serverless-edge-routing-config.md          ── 契约规范与消费模型文档更新

ai-workspace-infra/platform-ops-toolkit (PR #436)
  ├── scripts/serverless_uat/deploy_portal_opennext_worker.sh ── 提取 static_cdn_url 并注入 NEXT_PUBLIC_STATIC_CDN_URL
  └── scripts/serverless_uat/deploy_cloudflare_pages.sh       ── 提取 static_cdn_url 并注入 NEXT_PUBLIC_STATIC_CDN_URL
```

- **Portal PR**: [ai-workspace-services/portal#242](https://github.com/ai-workspace-services/portal/pull/242)
- **GitOps PR**: [ai-workspace-infra/gitops#169](https://github.com/ai-workspace-infra/gitops/pull/169)
- **Toolkit PR**: [ai-workspace-infra/platform-ops-toolkit#436](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/436)
