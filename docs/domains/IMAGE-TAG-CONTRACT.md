# 镜像 Tag 跨仓契约 (Image Tag Contract)

[`DELIVERY-MANIFEST.md`](DELIVERY-MANIFEST.md) 规定了 CD **消费**哪个 `deploy_tag`。
这份契约规定各服务仓的 CI Build 必须**生产**哪些 tag —— 两者必须严丝合缝，
否则 CD 会去 pull 一个从来没有被推送过的镜像。

> 这是**跨仓约定**，不是某一个仓库的实现细节。一个 `deploy_tag` 要同时寻址
> web-saas 域下的 Console、Accounts、Billing、Postgres 等多个仓库的镜像，
> 只要有一个仓库的 tag 规则不同，那个 `deploy_tag` 就是半可用的 ——
> 部分服务升级、部分服务停在旧版本，而部署本身会报成功。

## 契约

| 触发 | 环境 | CI 必须产出的镜像 tag |
|---|---|---|
| push tag `v*` | PROD | `v1.2.3`（原样，不加前缀） |
| push branch `release/v*` | PROD | `release-1.4`（`/` 在 docker tag 中非法，规范化为 `-`） |
| push branch `release/*`（不含 `release/v*`） | UAT | 仅作为 UAT 发布源，不得产出 PROD 发布制品 |
| 显式日快照 | UAT | `daily-build-YYYY.MM.DD-rN`（跨仓同名快照） |
| **任意一次构建** | SIT / 可追溯构建 | `sha-<40 位 full sha>` |

PROD 发布源是严格白名单：**仅** `refs/tags/v*` 与
`refs/heads/release/v*`。`main`、其他 `release/*` 分支、daily/UAT/SIT/snapshot/prod
标签以及其他 branch/tag/ref 均禁止进入 PROD；`deploy_env`、镜像 tag 名称、workflow
输入或脚本推断不能扩大这份白名单。日快照只服务 SIT/UAT，不得伪装成 PROD 发布。

最后一行是无条件的：**每一次构建都必须额外产出 `sha-<full>`**。SIT 的
`deploy_tag` 是「用户定义」，用户能定义的前提是存在一个稳定、可寻址、
跨仓一致的名字。短 sha 与长 sha 混用会让同一个值在一个仓库命中、在另一个
仓库落空。

## 规范实现

所有使用 `docker/metadata-action` 的仓库，`tags:` 块统一为：

```yaml
- uses: docker/metadata-action@v5
  with:
    images: <repo>
    tags: |
      type=ref,event=tag
      type=ref,event=branch,enable=${{ startsWith(github.ref, 'refs/heads/release/') }}
      type=sha,format=long
```

- `type=ref,event=tag` 让 `v1.2.3` 原样成为镜像 tag，与 PROD 的 `deploy_tag` 完全一致。
- `type=ref,event=branch` 只在 `release/*` 上启用；metadata-action 会自行把 `/` 换成 `-`。
  其中只有 `release/v*` 可作为 PROD 发布源，其他 `release/*` 仅用于 UAT；不加
  `enable` 的话 main 上会多产出一个 `main` tag，`main` 不是 PROD 发布源。
- `type=sha,format=long` 产出 `sha-<40 位>`（`sha-` 是 metadata-action 的默认前缀）。

触发范围也必须统一，否则 tag 规则写得再对也不会执行：

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main, 'release/**']
    tags: ['v*']
  workflow_dispatch:
```

**`main` 必须在 `push.branches` 里。** 缺了它，服务仓不会产出用于快照汇总的
构建制品。UAT 只能消费显式的跨仓快照 tag，绝不能以 `latest` 或 `main` 代替。

## 不用 metadata-action 的仓库

自己计算 tag 的仓库（例如用脚本推导 `IMAGE_TAG`）同样受本契约约束，
必须产出上表中的不可变 tag，且 sha 一律用 **40 位全长并带 `sha-` 前缀**。
裸 `${GITHUB_SHA}` 与 `sha-${GITHUB_SHA}` 是两个不同的 tag。

## 校验

新增或修改任何服务仓的构建 workflow 后，按此清单自查：

1. push 一个 `v*` tag，确认 GHCR 上出现同名 tag，且来源 ref 是 `refs/tags/v*`；
2. 从 `release/v*` 构建时，确认出现规范化的 `release-*` tag；从其他 `release/*`
   构建时，确认不得被当作 PROD 发布源；
3. 生成日快照时，确认每个受管服务都出现同名 `daily-build-*` tag，且只用于 SIT/UAT；
4. 任取一次构建，确认存在 `sha-<40位>`；
5. 同一服务的所有版本别名必须指向同一个 digest —— 它们是同一个镜像的别名，
   不是四次独立构建。
