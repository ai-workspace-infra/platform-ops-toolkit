# console 构建解阻 + PROD 直连审计 —— 记录

延续 [2026-07-25 工作计划](2026-07-25-delivery-chain-workplan.md) 的任务 1(五个
业务仓 CI 收敛)。本文档记录 portal 仓的收尾,以及顺带触发的一次安全审计。

## portal(console)构建从未成功过 —— 根因

`.gitignore:10` 排除了整个 `src/content/`。但 `scripts/generate-content.ts`
**读**这个目录生成 `src/data/content/*.ts`,排除源目录等于让生成器没有输入。

**为什么只在 CI 复现**:`.gitignore` 不影响已追踪文件。`hero.md` 系列文件在
排除规则加入前就已提交,`marketing.md`/`home.md` 是在那之后新增、从未被追踪。
于是构建在每台开发机上都成功(本地文件都在磁盘上)、在每个 CI runner 上都失败
(checkout 之后那些文件不存在)—— 报错点名的文件明明"看起来"就在那里。

修复:[portal#115](https://github.com/ai-workspace-services/portal/pull/115),
取消排除三个必需子目录(`homepage`/`docs`/`product`),`blogs`/`doc`(合计 1.8M)
保持排除,因为构建不读它们。验证方式是用 `git archive` 导出仅含已追踪内容的树、
在其中跑生成器 —— 不能用工作副本验证,工作副本正是掩盖问题的东西。

## 顺带审计:"任何构建版本都能直连 PROD 服务"

用户提出怀疑后审计,**结论成立,发现四条独立路径**,详见
[portal 仓的审计文档](../../../ai-workspace-service/portal/docs/audits/2026-07-25-runtime-env-prod-leak.md)。

| # | 路径 | 状态 |
|---|---|---|
| 1 | 环境检测全部链路落空,默认值是 `prod` | 已修:默认值改 `dev` |
| 2 | `base.yaml` 直接写生产地址,`sit.yaml` 漏覆盖 `authUrl`/`docsServiceUrl` | 已修:base 不再放端点 |
| 3 | **Dockerfile 硬编码 `RUNTIME_ENV=prod`**,第一级检测直接命中,路径 1 的修复根本走不到 | 已修:移到运行时注入([gitops#115](https://github.com/ai-workspace-infra/gitops/pull/115)) |
| 4 | `pipeline.yaml` 顶层 `env:` 硬编码生产域名到 `NEXT_PUBLIC_*`,编译进客户端 bundle | **未修**:需要 SIT 域名这个我推断不出的事实 |

路径 3 值得单独一提:最初审计断言"`RUNTIME_ENV` 从未被设置"是错的——它被设置
了,设成 `prod`,只是在当时检视范围外一层。**第一级分支已经命中时,改兜底值
没有任何作用。** 这是本次审计里最贵的一次误判,教训是:一个变量"从未被设置"
这类断言,必须验证到实际生效值(比如从某次 run 日志里读),不能只搜代码里有没有
显式赋值语句——赋值可能在别的文件里。

## 当前阻塞:Vault role 的 job_workflow_ref 落后于仓库重命名

五个业务仓的 workflow 文件统一改名为 `ci-pipeline.yml` 后(整合矩阵构建),
main push 全部在 `Load Vault secrets` 报:

```
error validating claims: claim "job_workflow_ref" does not match any
associated bound claim values
```

`docs/tasks/vault_auth_split.sh` **已经**包含 `ci-pipeline.yml`(与
`pipeline.yaml`/`pipeline.yml` 一起,三选一都放行),脚本本身是对的、
`bash -n` 通过。缺的是把它重新应用到 Vault ——这一步需要 admin token,
只能由用户执行:

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN=hvs.xxx
bash docs/tasks/vault_auth_split.sh
```

跑完后五个仓的 main 构建需要重新触发(push 或 workflow_dispatch)。

## 当前整体状态

- ✅ 五仓 CI 收敛完成、`.gitignore` 阻塞已解
- ✅ `console:latest` 首次成功构建过一次(合并 PR 时的那次 main push,发生在
  Vault role 过期之前)
- ⏳ 待用户跑 Vault role 脚本,重新验证 `console:latest` 稳定产出
- ⏳ 待重新触发 `platform-ops.yaml` 端到端,三层实机验证(流水线 / gitops /
  主机)
- 📝 [路径四](../../../ai-workspace-service/portal/docs/audits/2026-07-25-runtime-env-prod-leak.md#路径四next_public在-ci-顶层被硬编码为生产值)
  待修,需要 SIT 域名这一事实

## 相关

- [2026-07-25 工作计划](2026-07-25-delivery-chain-workplan.md) —— 陷阱清单、
  三项任务全貌
- [UAT 解阻记录](2026-07-23-uat-web-saas-deploy-unblocking.md) —— 前七层缺陷
- portal PR:[#113](https://github.com/ai-workspace-services/portal/pull/113)
  [#114](https://github.com/ai-workspace-services/portal/pull/114)
  [#115](https://github.com/ai-workspace-services/portal/pull/115)
  [#117](https://github.com/ai-workspace-services/portal/pull/117)
- [gitops#115](https://github.com/ai-workspace-infra/gitops/pull/115)
