# Cloudflare UAT 登录链路修复（跨界导航 + CORS 403 + 网关白名单 + 错误码映射）

> **Status**: 🟡 P0 编码中，PR 陆续提交；合并后需重新部署 UAT 才能验收
> **Date**: 2026-08-19
> **Related PRs**: accounts [#90](https://github.com/ai-workspace-services/accounts/pull/90) [OPEN] · 本仓 PR 待填 · edge-gateway 待创建 · portal 待创建
> **触发**: `https://console-cloudflare-uat.onwalk.net/` 登录按钮无效 + 登录页提交报「登录失败，请稍后再试。」

## 现象

两个表现，实际是**四个独立缺陷**，分布在三个仓库：

1. 首页右上角「登录」点击后**完全无反应** —— URL 不变、页面不变、console 零报错。
2. 直接访问 `/login` 输入正确账号密码，提示**「登录失败，请稍后再试。」**

生产 `console.svc.plus` 不受影响；SIT `console-cloudflare-sit.onwalk.net` 与 UAT 同病。

## 环境背景

`portal` 一套源码被 `scripts/build-open-next-boundary.mjs` 构建 **5 次**，产出 5 个
OpenNext worker（public / auth / content / console / workspace），由
`frontend-router` 按路径前缀分发（响应头 `x-frontend-route: ssr-*`）。每个 shard：
`assetPrefix: /_edge/<boundary>`、`generateBuildId: <boundary>-<GITHUB_SHA前16>`，
且 app 目录被 `owns()` 过滤 —— **public 构建里根本没有 `(auth)/login` 这个页面**。

API 侧：`/api/auth/*` → edge-gateway（auth boundary）→ Cloud Run `uat-accounts`。

## 缺陷清单与证据

### D1 · 跨 boundary `next/link` 对预渲染页静默挂死（portal）

- 首页的「登录」是 `next/link`（DOM 上挂着 React 的 `onClick`/`onMouseEnter`），
  Link 拦截点击做客户端软导航，拿到的是 **auth build 的 RSC payload**
  （`"b":"auth-…"` vs 当前 `"b":"public-…"`）。
- buildId 不匹配本应回退整页跳转（MPA）。实测**只对"动态"目标生效**：
  `/ai-workspace`、`/blogs`、`/docs`、`/support`、`/register` 均正常整页跳转；
  而 `/login`、`/logout` 是仅有的两个 `x-nextjs-prerender: 1` 静态预渲染页，
  点击后 router 去加载 `_edge/auth/_next/static/chunks/*.js`（全部 HTTP 200），
  但这些模块 id 属于 auth 的 turbopack runtime，在 public runtime 里永不解析 →
  React transition 永不 commit → URL 不提交、无异常。
- 预渲染的开关是 `src/app/(auth)/login/page.tsx` 的 `export const dynamic = "error"`。
- 判别手法：页面里 `window.__M='x'` 后点击，`__M` 丢了 = 整页跳转（正常）；
  `__M` 还在且 URL 没变 = 软导航挂死（本缺陷）。

### D2 · accounts CORS 白名单缺 UAT/SIT 域名 → 浏览器登录一律 403（accounts）⚠️ 主因

- 同一请求只差一个 header：

  | 请求 | 结果 |
  |---|---|
  | `POST /api/auth/login`（无 Origin） | `401 application/json {"error":"invalid_credentials"}` |
  | 同上 + `Origin: https://console-cloudflare-uat.onwalk.net` | **`403 text/html`，content-length 0** |
  | 同上 + 仅 `Referer` | 401 JSON（不触发） |
  | 同上 + 仅浏览器 `User-Agent` | 401 JSON（不触发） |

- 空 body 的 403 是 gin-contrib/cors `AbortWithStatus(403)` 的签名。
  白名单在 `cmd/accountsvc/main.go:1866`（`AllowOriginFunc`）+
  `resolveAllowedOrigins()`，数据来自 `config/account.cloudrun.yaml:33`
  的 `allowedOrigins`，其中只有 `https://console.svc.plus`，**没有任何
  `*-cloudflare-*.onwalk.net`**。
- Cloud Run 部署用的就是该文件（`scripts/serverless_uat/deploy_cloudrun_services.sh:54`
  的 `CONFIG_TEMPLATE=/app/config/account.cloudrun.yaml`），且部署脚本
  **不传任何 origin 相关 env**，容器 `entrypoint.sh` 只做 `envsubst` 渲染。
- edge-gateway 自己回了 `Access-Control-Allow-Origin: *`，掩盖了这是 CORS 问题 ——
  浏览器不报 CORS 错，只表现为一个"应用错误"。

### D3 · edge-gateway 免鉴权白名单漏掉三个登录前接口（edge-gateway）

`src/config.ts:23` 的 `PUBLIC_PATHS` 缺以下**未登录状态必须可达**的路径，
实测匿名访问全部 `401 Missing or invalid Bearer token`：

| 接口 | 调用方 | 影响 |
|---|---|---|
| `/api/auth/mfa/status` | `LoginForm.tsx:77`，输入用户名后探测验证方式 | 「验证方式」下拉恒为空灰占位，静默 `setMfaRequirement("optional")` |
| `/api/auth/token/exchange` | `LoginContent.tsx:100`，OAuth 回调换 session | GitHub/Google 登录回调链路断 |
| `/api/auth/verify-email`(+`/send`) | 邮箱验证流程 | 邮箱未验证的用户无自救路径 |

注意 `/api/auth/mfa/setup`、`/api/auth/mfa/verify` 是**登录后**操作，不得加入白名单。

### D4 · 前端错误码映射不全，把可诊断状态压成「请稍后再试」（portal）

`LoginForm.tsx:196-241` 的 switch 只映射 7 个码，`default` → `genericError`
（`translations.ts:1676` = 「登录失败，请稍后再试。」）。而 accounts 的
`api/api.go` 里 login 路径可返回的码远不止这些，以下**全部**落到 default：

- `email_not_verified`(401) —— 全仓 grep 0 处映射
- `account_suspended`(403)、`sandbox_no_login`(403)、`password_required`(401)
- `authentication_failed`(500)、`billing_state_unavailable`(503)
- `mfa_required` / `mfa_setup_required`（会 `setMfaRequirement` 却仍显示 generic）

且 D2 的 403 空 body 经 `response.json().catch(() => ({}))` 退化成 `{}`，
`payload.error` 为 undefined → `messageKey = "generic_error"` → 同样落 default。
**即使修好 D2，只要后端返回任何未映射的码，用户仍然只能看到"请稍后再试"。**

## 共性根因

同一份契约知识被复制在多处，且**没有任何契约测试**把它们钉在一起：

| 知识 | 副本位置 |
|---|---|
| 路径 → SSR boundary | `frontend-router/src/routes.ts` · `portal/scripts/build-open-next-boundary.mjs` 的 `owns()` · `portal/config/cloudflare-boundaries.json` |
| 哪些 API 免鉴权 | `edge-gateway/src/config.ts` 的 `PUBLIC_PATHS` vs portal 里散落的 16 个 fetch 调用点 |
| 允许的浏览器 Origin | `accounts/config/*.yaml` 的 `allowedOrigins` vs GitOps `EdgeRoutingConfig` 的 `console_host` |
| accounts 错误码 | `accounts/api/*.go` 的 40+ 处 `respondError` vs `LoginForm.tsx` 手写的 7 个 case |

每新增一个环境/页面/接口/错误码就要人肉同步 2–3 处，漏一处就是一次静默故障。
本次四个缺陷全部是这个模式的实例 —— D2 尤其典型：新环境 `console-cloudflare-uat`
上线时，`console_host` 只进了 GitOps 和 Cloudflare 路由，没有进 accounts 的 CORS 白名单。

## 修复计划

### P0 · 止血（目标：UAT 能登录）

| # | 仓库 | 改动 |
|---|---|---|
| P0-1 ✅ | accounts | `resolveAllowedOrigins()` 增加读取 `ALLOWED_ORIGINS` 环境变量（逗号分隔，与配置文件列表**合并**，复用现有 `parseOrigin` 归一化、`*` 通配与去重）。**最终没有再加 yaml 模板槽** —— 两个开关做同一件事正是本次故障的成因，没必要再造一份副本。[accounts#90](https://github.com/ai-workspace-services/accounts/pull/90) |
| P0-2 ✅ | platform-ops-toolkit | `deploy_orchestrator.py` 新增 `resolve_console_origins()`，从 GitOps `EdgeRoutingConfig` 推导浏览器 Origin：`spec.serverless.console_host` + `canonical_records` 与 `spec.domains` 里指向同一 host 的别名（`console-uat.onwalk.net` 也是用户会用的入口，它发出的 Origin 是别名本身）。`deploy_cloudrun_services.sh` 透传给 accounts；`cloud_run` job 补上 GitOps checkout + render 步骤。新增契约测试并接入 `validate-release-pr.yml` |
| P0-3 | edge-gateway | `PUBLIC_PATHS` 追加 `/api/auth/mfa/status`、`/api/auth/token/exchange`、`/api/auth/verify-email`（`matchesPath` 走前缀匹配，一条覆盖 `/send`）；`/api/v1/auth/*` 同步补齐 |
| P0-4 | portal | `LoginForm.tsx` 的 switch 补齐上列错误码；`default` 分支改为**带上原始 error code 与 HTTP status**（如「登录失败（403 / generic_error）」），杜绝下一次再从零排查 |
| P0-5 | portal | `(auth)/login/page.tsx` 与 `logout` 的 `export const dynamic = "error"` 改为 `force-dynamic`，让 D1 走与其它跨界路由一致的 MPA 回退 |

### P1 · 根治

| # | 仓库 | 改动 |
|---|---|---|
| P1-1 | portal | `BoundaryLink` 组件替代跨界 `next/link`：boundary 前缀表提为共享常量（由 `cloudflare-boundaries.json` 生成，与 `frontend-router/src/routes.ts` 同源），当前 boundary 由 `build-open-next-boundary.mjs` 注入 `env.NEXT_PUBLIC_EDGE_BOUNDARY`，跨界渲染原生 `<a>`。跨界 href 共 **59 处 / 28 个文件**，逐个改不现实 → 在 boundary 构建里给 `next/link` 加 alias 指向该组件，单点生效 |
| P1-2 | accounts + portal | 从 `api/*.go` 的 `respondError` 抽出全部错误码，生成 TS 联合类型；前端映射表声明为 `Record<AuthErrorCode, string>` —— 漏一个码**编译失败**，而不是运行时变成「请稍后再试」 |
| P1-3 | portal + edge-gateway | portal 所有 pre-auth fetch 收敛到 `lib/publicAuthApi.ts` 并导出路径清单；edge-gateway 的 `PUBLIC_PATHS` 与该清单做交叉断言 |

### P2 · 守卫（防回归）

| # | 位置 | 检查 |
|---|---|---|
| P2-1 | portal CI | lint：禁止 `next/link` 的 href 命中他 boundary 前缀 |
| P2-2 | toolkit（挂在 `verify_frontend_boundary_assets.sh` 旁） | 匿名 GET 每个 pre-auth 接口，断言**不是 401** |
| P2-3 | 同上 | **带 `Origin: https://<console_host>`** POST `/api/auth/login`，断言**不是 403**（这一条直接拦住 D2；不带 Origin 的探测永远发现不了） |
| P2-4 | 同上 | 点击首页「登录」，断言 URL 变成 `/login`（拦住 D1） |
| P2-5 | 同上 | 用专用测试账号跑一次完整登录，断言拿到 session cookie |

## 验收标准

1. `curl -H 'Origin: https://console-cloudflare-uat.onwalk.net' -X POST .../api/auth/login` 返回 **JSON**（401/200），不再是空 body 403。
2. 匿名 `GET /api/auth/mfa/status?identifier=<x>` 不再 401。
3. 首页点「登录」跳到 `/login`。
4. 真实账号在浏览器完成登录并拿到 session。
5. 失败场景（错密码 / 邮箱未验证 / MFA）各自显示**可区分**的中文提示。
6. SIT 同样通过；生产 `console.svc.plus` 行为无变化（回归验证）。

## 遗留 / 不在本次范围

- run 32219430536 的 `Data Migration / Supabase / Migrate PostgreSQL Metadata` 失败
  （`pg_dump` 经 `accounts-vps-uat.onwalk.net:15433` 隧道时被对端断开）—— 与登录链路无关，另行处理。
- `/_vercel/insights/script.js` 404、DataFast 403、若干 `/_next/image` 404 —— 噪音，不影响功能。
- `/dashboard` 在 ssr-console 返回 404（预渲染），需确认是否为有效路由。
