# Agent workflow_dispatch 目录

本文档是给对话式 Agent（例如 XWorkmate 的 Harness Workflow 插件）看的**本仓库专属**目录：
哪些 `workflow_dispatch` 可以派发、每个输入实际做什么、哪些输入是死的、哪些组合非法、
派发后该核对什么证据。通用的"如何安全派发/确认/验收"纪律见 skill
`github-actions-operational-dispatch`（`xworkspace-core-skills` 仓库），本文档只放
"这个仓库具体是怎样"的事实，随 workflow 改动同步维护，不要让通用 skill 里出现会漂移的
本仓库细节。

更新时间：2026-08-02（对应 `main@3915e54`）

---

## 1. `cron-rotate-domain-tls-certs.yaml` —— 零输入

`workflow_dispatch:` 没有任何 inputs，派发体只需要 `ref`。

- `VAULT_ROLE: github-actions-platform-ops-toolkit-prod`。`docs/tasks/vault_auth_split.sh`
  （2026-07-29 改动 `3f30381d`）里该 role 绑定的是
  `["refs/tags/v*", "refs/heads/main"]`，**从 `main` 派发理论上可以通过 Vault 认证**。
  ⚠️ **但 `docs/README.md` 里 2026-07-22 写的"PROD 只能由 `v*` tag 触发，
  workflow_dispatch 选 prod 会认证失败"这条说明比脚本改动更早、没有同步更新**——
  两处目前互相矛盾。脚本是实际配置 Vault 的操作代码，理应更权威，但没有对 Vault
  实例做过运行时校验。**派发前如果对认证结果没有把握，先跑一次空推验证（或让运维确认
  当前 Vault 里的 role 绑定），不要直接假定二者中的任意一个成立。**
- 没有参数，agent 侧价值全在验收：run 结论为 success 不代表证书真的换了。

**验收**：不要只看 run 结论。查实际证书有效期/签发时间。已知故障模式——
Let's Encrypt 对同一组域名限流 5 次/168h（`too many certificates ... retry after ...`）；
命中限流窗口期内**任何重跑都无效**，应直接告知用户"等窗口过期"，不要建议重试。

---

## 2. `daily-main-snapshot.yaml` —— 4 个输入，一个是死的

| input | 类型 | 现状 |
|---|---|---|
| `snapshot_tag` | string | 留空 → `daily-build-$(date -u +%Y.%m.%d)` |
| `snapshot_source_ref` | string | **死输入，见下** |
| `deploy_env` | choice：sit / uat / prod | 默认 `uat` |
| `repositories` | string，逗号分隔 | 留空 → 默认 5 个业务仓（accounts / billing-service / docs / portal / postgresql.svc.plus） |

- **`snapshot_source_ref` 从未生效**：workflow 把它作为 `SNAPSHOT_REF` 传进 step
  （`.github/workflows/daily-main-snapshot.yaml`），但
  `.github/scripts/tag-daily-main-snapshot.sh` 里 `args=(--tag "${tag}" --ref main ...)`
  写死 `--ref main`、从不读 `SNAPSHOT_REF`。**Agent 不要把这个字段当作可用输入呈现给
  用户**；如果用户明确要求非 main 的 source ref，应告知该字段当前不生效，而不是假装
  已生效地派发。
- **tag 命名两套约定并存**：脚本默认产出**不带环境前缀**的 `daily-build-YYYY.MM.DD`；
  另一套运维口径是 `uat-daily-build-YYYY-MM-DD-rN` 这类带前缀的 tag。
  `docs/tasks/tag-ai-workspace-mains.sh` 的 `infer_deploy_env_from_tag()` 按前缀
  （`v*`→prod，`release/*`→uat，`sit-*`/`snapshot-*`→sit，`uat-*`→uat，`prod-*`→prod，
  其余一律兜底 `uat`）推断部署环境，从而决定换哪个 Vault role。**默认让 `snapshot_tag`
  留空、用 workflow 自带的默认值**；只有用户明确要自定义 tag 时才手填，并提醒对方
  前缀会影响后续认证路由。
- 矩阵横跨 4 个 org（`ai-workspace-infra` / `ai-workspace-lab` / `ai-workspace-services` /
  `ai-workspace-xstream`），且 `wait-daily-snapshot-builds.sh` 还要等下游各仓构建完成 →
  单次 run 是分钟级甚至更久，观察节奏不要按秒级 CI 的预期来卡超时。

**验收**：run 绿不等于每个仓都真的打上了预期的 tag/release。逐仓核对
`gh release view <tag> -R <repo>` 或对应的 assets 是否存在（`wait-daily-snapshot-builds.sh`
本身就是这道验收，本条只是提醒 agent 不要跳过它、也不要只看 job 结论）。

---

## 3. `platform-ops.yaml` —— 约 20 个输入，危险项最多

### 3.1 隐式规则（都是脚本/工作流硬编码的行为，不在 YAML schema 里可见）

来源：`.github/scripts/platform-ops_provision_route-ref-to-an-explicit-profile.sh`
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
5. `instance_plan` 只真正作用于 web-saas 主机。`agent-proxy.yaml` 的 host plan 是
   **硬编码 `vc2-1c-2gb`**，完全不读 `INSTANCE_PLAN_API`。
   `.github/scripts/platform-ops_provision_map-instance-plan.sh` 里"agent-proxy 默认
   1C2G"的特判只在 `target_domains == "agent-proxy"` 且 `instance_plan == "4C8G"` 时
   触发，选 `"web-saas + agent-proxy"` 不会走到这条特判——但结果恰好也是 1C2G，只是
   路径不同，agent 不要把这两件事记混。
6. `target_domains="web-saas + agent-proxy"` 走 `rf="web-saas-agent-proxy"`，Terraform
   workspace 是 `uat-vultr-vps-platform-ops-toolkit-web-saas-agent-proxy`，state key 是
   `uat/vultr-vps/platform-ops-toolkit/web-saas-agent-proxy.tfstate`——**与 `all` /
   `web-saas` 用的 `...-web-saas` 不是同一份 state**。派发这个组合是**新建两台主机**，
   不是给现有 `console-uat` 那台加一个 agent-proxy。这条必须在确认环节向用户说清楚，
   避免被理解为"扩容现有环境"。
7. `concurrency.group: deploy-env-migration` + `cancel-in-progress: false` → 全局串行
   排队。派发后长时间停在 `queued` 是正常现象，不要当作卡死去重新派发（重复派发只会
   排更久的队）。
8. `switch_dns` job 挂 `environment: production`（需要 GitHub Environment 审批）且要求
   `confirm_dns_switch == 'true'`；而常规的 `observe_web_saas` job **不看**
   `confirm_dns_switch`，用 `OBSERVE_RESOLVE_IP` 把域名钉到本次部署的 IP 上做验收，
   DNS 没切也能跑通。**默认不要替用户勾选 `confirm_dns_switch`**——它是"接管生产流量"，
   不是"验证部署成功"。

### 3.2 危险字段清单（派发前必须让用户对该字段本身给出明确确认）

- `action=destroy`
- `confirm_dns_switch=true`
- `vault_env_path=prod`
- `run_full_stack=true`（会连带打开上面两条）

### 3.3 三个目标任务对应的参数（2026-08-02 已核实的具体案例）

**任务：拉起 UAT web-saas + agent-proxy**
```
ref: main
vault_env_path=uat, target_domains="web-saas + agent-proxy",
cloud_provider=vultr-vps, instance_plan=2C4G, action=deploy,
run_infrastructure=true, run_application_deploy=true,
target_domain_base=onwalk.net, deploy_tag=<gitops 已 pin 的值>,
confirm_dns_switch=false
```
结果：web-saas 主机 `vc2-2c-4gb`（2C4G）、agent-proxy 主机 `vc2-1c-2gb`（1C2G），
两台都是新建（独立 state），DNS 只做 observe、不切流量。

---

## 4. `data-migration.yaml`

同时有 `workflow_call` 与 `workflow_dispatch` 两套 inputs，字段同名但类型不同
（`workflow_call` 版是 string，`workflow_dispatch` 版是 choice）。Agent 只需要对
`workflow_dispatch` 版建模。`toolkit_action=restore` 与 `vault_env_path=prod`
同时出现是本仓库风险最高的组合，按 §3.2 的规格同等对待——需要用户对这两个字段本身
分别确认。

---

## 5. 验收：run 绿不等于事情做成

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

## 6. 边界

Agent 只允许对本文档列出的四个 workflow 调用 `workflow_dispatch`，不得为了绕过触发
规则新建分支/tag/PR，不得修改这些 workflow 本身、其脚本、或它们部署的目标仓库
（gitops、Vault）作为让派发"成功"的手段。遇到现有触发/授权规则无法满足的合法请求，
如实告知用户这是需要人工调整路由/角色绑定的问题，不要绕过。
