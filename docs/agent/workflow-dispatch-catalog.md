# Agent workflow_dispatch 目录

本文档是给对话式 Agent（例如 XWorkmate 的 Harness Workflow 插件）看的**本仓库专属**目录：
哪些 `workflow_dispatch` 可以派发、每个输入实际做什么、哪些输入是死的、哪些组合非法、
派发后该核对什么证据。通用的"如何安全派发/确认/验收"纪律见 skill
`github-actions-operational-dispatch`（`xworkspace-core-skills` 仓库），本文档只放
"这个仓库具体是怎样"的事实，随 workflow 改动同步维护，不要让通用 skill 里出现会漂移的
本仓库细节。

更新时间：2026-08-21

---

## 1. `cron-rotate-domain-tls-certs.yaml` —— 零输入

`workflow_dispatch:` 没有任何 inputs，派发体只需要 `ref`。

- `VAULT_ROLE: github-actions-platform-ops-toolkit-prod`。PROD role 的来源白名单必须
  严格限制为 `refs/tags/v*` 与 `refs/heads/release/v*`。若 Vault role、workflow 或
  运行时脚本仍允许 `main`、其他 `release/*`、daily/UAT/SIT/snapshot/prod 标签或其他
  来源，这是安全漂移，不构成合法的 PROD 路由；文档不能把漂移行为视为允许项。派发前
  应核对实际 Vault role 绑定和 run 的 `github.ref`，并按失败关闭处理。
- 没有参数，agent 侧价值全在验收：run 结论为 success 不代表证书真的换了。

**验收**：不要只看 run 结论。查实际证书有效期/签发时间。已知故障模式——
Let's Encrypt 对同一组域名限流 5 次/168h（`too many certificates ... retry after ...`）；
命中限流窗口期内**任何重跑都无效**，应直接告知用户"等窗口过期"，不要建议重试。

---

## 2. `daily-main-snapshot.yaml` —— 4 个输入

| input | 类型 | 现状 |
|---|---|---|
| `snapshot_tag` | string | 留空 → `daily-build-$(date -u +%Y.%m.%d)` |
| `snapshot_source_ref` | string | 留空使用 `main`；也可指定明确的 source ref |
| `deploy_env` | choice：sit / uat / prod | 默认 `uat`；选择 `prod` 也不能绕过 PROD 来源白名单 |
| `repositories` | string，逗号分隔 | 留空 → 仅当前构建清单中的 6 个仓（accounts / billing-service / content-service / portal / postgresql.svc.plus / xworkmate-bridge） |

- **`snapshot_source_ref` 已生效**：该值会作为 `SNAPSHOT_REF` 传给打 tag 脚本；新 tag
  固定指向所选 ref。不能用同一个 tag 改指向另一个提交，需使用新的 retry tag。
- **tag 命名规范与强制约束**：
  - **必须包含 `daily-build-`**：脚本默认产出 `daily-build-YYYY.MM.DD`，自定义通常为 `uat-daily-build-YYYY.MM.DD-rN`。
  - **严禁使用 `v*`（如 `v2026.08.15`）或 `*-release-*` 等 release 形状的 tag**：
    1. 各 Service CI 的 release asset 发布（`release-manifest.json`）仅对 `daily-build-*` 生效；非 daily-build tag 会导致 CI 虽绿但 manifest 缺失。
    2. `v*` tag 会被多环境路由规则直接路由给生产（`prod`）环境，产生灾难性误投产风险。
  - `docs/tasks/tag-ai-workspace-mains.sh` 的 `infer_deploy_env_from_tag()` 按前缀
    （`v*`→prod，`release/*`→uat，`sit-*`/`snapshot-*`→sit，`uat-*`→uat，`prod-*`→prod，
    其余一律兜底 `uat`）推断部署环境，从而决定换哪个 Vault role；这只是实现细节，不能
    取代来源 ref 白名单。PROD **仅**允许 `refs/tags/v*` 或 `refs/heads/release/v*`，
    `prod-*`、daily-build、uat-daily-build、sit、snapshot 及其他 branch/tag 均不得获得
    PROD 权限。**默认让 `snapshot_tag` 留空、用 workflow 自带的默认值**；只有需要加入新
    commit 时才指定带 revision 后缀的 tag（如 `uat-daily-build-2026.08.15-r6`）。
- **tag 不可变性**：快照 tag 不会移动或覆盖已存在的 git tag。若 main 分支有新代码需构建，必须使用新的 revision 后缀（`-r2`, `-r3` 等）。
- **tag 废弃与忽略准则（禁止物理删除）**：
  - 若某个 tag（如 `v2026.08.15` 或 `uat-daily-build-*`）因打错、严重缺陷或路由错误被废弃，**严禁从远端物理删除 tag**（保留审计历史与构建痕迹）。
  - **Release 废弃操作**：通过 `gh release edit <tag>` 将标题标记为 `[DEPRECATED] <tag>`，状态降级为 `Pre-release`，并在 Notes 顶部添加包含替代版本的 `> [!CAUTION]` 警示公告。
  - **GitOps 与部署隔离**：环境配置文件（`.env.uat` / `.env.prod`）中禁止引用被废弃的 tag；修复必须以全新的 revision 或 patch tag 发布。
- 矩阵横跨 4 个 org，但每个 job 只处理归属本 org 的构建清单仓库；infra、xstream 当前
  没有清单目标，会直接跳过。每个仓库有独立等待预算，某个仓没有 run 不会把后续仓库
  已完成的构建误判为超时。`xworkmate-bridge` 不接收 daily tag push，而是在 tag 创建后
  显式 `workflow_dispatch`（`environment=uat`、`run_apply=false`）。

**验收**：run 绿不等于每个仓都真的打上了预期的 tag/release。逐仓核对
`gh release view <tag> -R <repo>` 或对应的 assets 是否存在（`wait-daily-snapshot-builds.sh`
本身就是这道验收，本条只是提醒 agent 不要跳过它、也不要只看 job 结论）。

---

## 3. `serverless-orchestrator.yml` —— UAT 自动发布与数据同步

`daily-main-snapshot.yaml` 在完整 UAT 服务快照构建完成后会按组合式顺序派发
`serverless-orchestrator.yml` 与 `selfhost-orchestrator.yml`。第一条调用明确传入
`operation=deploy+migrate`、`vault_env_path=uat` 与不可变 `tag_ref`，并明确传入
`supabase_target_existing_strategy=accounts_merge`，因此 UAT 已有 public 表时不会因
可复用迁移工作流的默认 `reject` 而中止；Accounts 的 `migratectl --merge` 只增量合并
用户、身份和会话数据，不删除 UAT 行。手工派发也默认使用 `accounts_merge`。

Serverless 工作流成功完成并通过 Accounts 验证后，组合派发器才会继续调用
`selfhost-orchestrator.yml`，参数固定为 `operation=deploy`、`vault_env_path=uat`、
`target_domains=agent-proxy` 与同一个 `deploy_tag`。Agent Proxy 的
`agent_controller_url` 指向本次 Serverless Web SaaS 的
`https://accounts-serverless-uat.onwalk.net`，所以注册不会误连到 Selfhost Accounts；
手工 Selfhost 派发若不提供该输入，仍回退到同一 Selfhost Web SaaS Accounts。

组合派发只在完整矩阵成功且 `repositories` 为空时执行；部分仓库筛选不会解析 TAG，也不会
派发任一下游环境。

只有 UAT 可废弃且操作者明确确认时，才选择
`supabase_target_existing_strategy=replace_public` 并勾选
`supabase_target_confirm_replace=true`。流水线会先上传 public schema/data 备份，再清理
目标 public 对象并导入 PROD 快照；未提供确认或选择 `reject` 时不会写入非空目标。

这条自动链路也是 XWorkmate/OpenClaw 插件应调用的唯一入口：插件只负责派发带 immutable
`uat-daily-build-*` tag 的工作流和轮询结果，不直接持有 Vault、数据库或 Cloudflare
凭据。XWorkmate APP 应连接 `XWORKMATE_BRIDGE_SERVER_URL`（UAT 默认
`https://bridge-uat.onwalk.net`）。`accounts-uat.onwalk.net` 是受用户密码 + MFA 保护的
轻量 IAM/多租户管理面，应由 Bridge 代为校验和分发认证上下文；插件不能绕过 MFA 或直连
Accounts 内部接口。完整
工具契约见 [`xworkmate-openclaw-uat-automation.md`](xworkmate-openclaw-uat-automation.md)。
验收至少包含 workflow conclusion、Accounts merge 的 no-op replay，以及 UAT
`/panel/management` 顶部汇总和用户列表的真实接口响应。

## 4. `platform-ops.yaml` —— 约 20 个输入，危险项最多

### 3.1 隐式规则（都是脚本/工作流硬编码的行为，不在 YAML schema 里可见）

来源：`.github/scripts/platform-ops/provision/platform-ops_provision_route-ref-to-an-explicit-profile.sh`
与 workflow 头部注释。

1. `run_application_deploy=true` 必须同时 `run_infrastructure=true`，否则脚本
   `echo "::error::..." && exit 1`（部署用的 inventory/CMDB 是 provision 阶段才生成的）。
2. `run_full_stack=true` **强制覆盖**上述两个开关为 `true`，并强制打开 DNS 发布——
   这是显式覆盖，不是 `||` 兜底，即使同时传入 `false` 也不会被削弱。
3. `action=destroy` 强制 `run_infrastructure=true` / `run_application_deploy=false`，
   不受两个复选框实际取值影响。
4. `deploy_tag` **必填**，且 CD 是 **pull-only**：gitops 侧只消费已经 pin 的镜像 tag，
   从不会因为这次派发而反向写入 gitops。传一个 gitops 没有 pin 的 tag 会在 Deploy
   Web SaaS 阶段**主动 fail**，报 `gitops pins 'latest', requested '<tag>'`。这是设计内
   守卫，不是故障——真要部署某个 tag，必须先改
   `ai-workspace-infra/gitops` 的 `compose/web-saas/.env.uat`（契约见该仓
   `docs/domains/IMAGE-TAG-CONTRACT.md`）。**Agent 派发前应先确认 `deploy_tag` 是否已被
   gitops pin**，而不是等 20 分钟后的 CI 失败去发现。
5. `instance_plan` 只真正作用于 web-saas 主机。Agent Proxy 使用独立的
   `agent_proxy_plan` 输入，默认 `1C1G`，可显式选择 `1C2G`；它通过
   `AGENT_PROXY_PLAN_API` 注入对应云厂商的资源声明，不再硬编码到
   `agent-proxy.yaml`，也不会被 Web SaaS 规格意外覆盖。
6. `target_domains="web-saas + agent-proxy"` 走 `rf="web-saas-agent-proxy"`，Terraform
   workspace 是 `uat-vultr-vps-platform-ops-toolkit-web-saas-agent-proxy`，state key 是
   `uat/vultr-vps/platform-ops-toolkit/web-saas-agent-proxy.tfstate`——**与 `all` /
   `web-saas` 用的 `...-web-saas` 不是同一份 state**。派发这个组合是**新建两台主机**，
   不是给现有 `console-uat` 那台加一个 agent-proxy。这条必须在确认环节向用户说清楚，
   避免被理解为"扩容现有环境"。
7. `concurrency.group: deploy-env-migration` + `cancel-in-progress: false` → 全局串行
   排队。派发后长时间停在 `queued` 是正常现象，不要当作卡死去重新派发（重复派发只会
   排更久的队）。
8. 最后的交付阶段按固定顺序执行：`switch_dns` 只负责 DNS 更新；随后
   `observe_web_saas_after_dns` 与 `observe_agent_proxy_after_dns` 两个 matrix job
   并列检查服务状态和公网端点；最后 `deployment_summary` 汇总部署、DNS、服务状态和
   数据迁移结果。服务验收不再在 DNS 更新前执行。

### 3.2 危险字段清单（派发前必须让用户对该字段本身给出明确确认）

- `action=destroy`
- `dns_mode=prod-cutover`
- `vault_env_path=prod`（仅允许来源 ref 为 `refs/tags/v*` 或 `refs/heads/release/v*`）
- `run_full_stack=true`（会连带打开上面两条）

### 3.3 三个目标任务对应的参数（2026-08-02 已核实的具体案例）

**任务：拉起 UAT web-saas + agent-proxy**
```
ref: main
vault_env_path=uat, target_domains="web-saas + agent-proxy",
cloud_provider=vultr-vps, instance_plan=2C4G, action=deploy,
run_infrastructure=true, run_application_deploy=true,
target_domain_base=onwalk.net, deploy_tag=<gitops 已 pin 的值>,
dns_mode=none
```
结果：web-saas 主机 `vc2-2c-4gb`（2C4G）、agent-proxy 主机默认 `vc2-1c-1gb`（1C1G）；
如需兼容旧规格，在 dispatch 时把 `agent_proxy_plan` 设为 `1C2G`。
两台都是新建（独立 state），DNS 只做 observe、不切流量。

---

## 5. `data-migration.yaml`

同时有 `workflow_call` 与 `workflow_dispatch` 两套 inputs，字段同名但类型不同
（`workflow_call` 版是 string，`workflow_dispatch` 版是 choice）。Agent 只需要对
`workflow_dispatch` 版建模。`toolkit_action=restore` 与 `vault_env_path=prod`
同时出现是本仓库风险最高的组合，按 §3.2 的规格同等对待——需要用户对这两个字段本身
分别确认。

---

## 6. 验收：run 绿不等于事情做成

这条流水线的历史故障几乎都是"绿而未成"，agent 派发后不能只看 run 的
`conclusion`：

- **建库/部署类**：`ansible-playbook --list-hosts` 命中数为 0 时 `--limit` 与
  playbook 自身 `hosts` 模式求交为空，仍然 `exit 0`——这是已经发生过的真实事故
  （`deploy_accounts_svc_plus.yml` 的 `hosts: accounts`，而 CMDB 从未打过 `accounts`
  这个组）。验收要落到服务端点：`accounts-uat.onwalk.net/` 返回 **404 是正常的**
  （该服务只挂 `/api/*`），要打 `/api/account/service-readiness` 看到 **401**
  才算通；console 可在主机内
  `docker exec web-saas-caddy wget -qS -O /dev/null http://console:3000/` 看 200。
- **证书轮换**：见第 1 节，命中 Let's Encrypt 限流时不要重试。
- **快照打 tag**：见第 2 节，逐仓核对 release/assets 是否真的存在。

---

## 7. 边界

Agent 只允许对本文档列出的四个 workflow 调用 `workflow_dispatch`，不得为了绕过触发
规则新建分支/tag/PR，不得修改这些 workflow 本身、其脚本、或它们部署的目标仓库
（gitops、Vault）作为让派发"成功"的手段。遇到现有触发/授权规则无法满足的合法请求，
如实告知用户这是需要人工调整路由/角色绑定的问题，不要绕过。
