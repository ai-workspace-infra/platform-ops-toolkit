# 交付链工作计划：CI 收敛 → compose 补全 → UAT 端到端

面向**交接**写的：假设接手者没有本会话上下文，也不熟悉这套仓库。每项任务都给出
可执行的验收命令与期望输出，不留需要推断的地方。

> **最重要的一节是 [§0 陷阱清单](#0-陷阱清单必读)。** 这条链路上的缺陷有一个共同
> 形态：**它们不报错**。假绿、静默 skip、空值渲染、自动创建的空目录——run summary
> 上一片绿而实际什么都没发生。不先读这一节，会把时间花在重复发现同样的坑上。

---

## 0. 陷阱清单（必读）

本会话实际踩到并修复过的，每一条都曾让某个 job 报绿或报一个与真实原因无关的错。

### GitHub Actions

| # | 陷阱 | 症状 | 判据 / 修法 |
|---|---|---|---|
| 1 | **skip 沿 `needs` 链传递**，`always()` / `!cancelled()` 只为携带它的那个 job 挡一次 | 下游 job 的 `if` 每个操作数都成立，却永远 skip | step 层 gate 跑了、job 层 gate 跳了 → 值是好的、传递是坏的。等价地：恰好带 guard 的 job 都跑了、不带的都跳了 → 被测的不是条件 |
| 2 | `if: >-` 折叠标量：比首行缩进更深的行**保留换行** | `"${{\n a &&\n b\n}}"` 是字符串，永不求值 | 所有操作数对齐到同一列 |
| 3 | 脚本 git mode `100644` 却被 `run:` 裸调用 | exit 126 Permission denied，日志只有 env 块 | `git update-index --chmod=+x <path>` |
| 4 | `needs.<x>` 引用了不在 `needs:` 里的 job | 解析为空串 → 条件永久为假 | 见 §0 的守卫脚本 |
| 5 | **跨仓 `workflow_call` 时 `github.repository` 是调用方的** | `actions/checkout` 拉错仓库 → exit 127 找不到脚本 | 显式写 `repository:` + `ref:` |
| 6 | PR 以另一个未合分支为 base | 合并后内容**没进 main** | 合并前确认 `baseRefName == main` |
| 7 | job 的 checkout 与依赖 PR 的合并**前后脚** | 拉到合并前的代码，失败原因看似已修好的 bug | 依赖 PR 合并后等 1 分钟再触发 |

**守卫脚本**：`scripts/ci/workflow_gating_verify.py`（已接入 `validate-release-pr.yml`）
覆盖 #1#2#3#4。改任何 job 条件后跑它：

```bash
python3 scripts/ci/workflow_gating_verify.py    # exit 0 = 通过
```

### Vault

| # | 陷阱 | 症状 | 修法 |
|---|---|---|---|
| 8 | **`vault-action` 的 `ignoreNotFound` 只覆盖整个路径 404**，不覆盖"路径存在、单个键缺失" | `Unable to retrieve result for data.data."X". No match data was found.` | 可选键必须自己读（见 `domain-cd-load-gitops-token.sh`、`platform-ops_deploy_base_load-optional-web-saas.sh`），不能靠这个开关 |
| 9 | Vault role 的 `repository` claim 同样是**调用方**仓库 | 跨仓调用时认证必失败 | 绑调用方 repo + `job_workflow_ref` 钉被调用方 workflow |
| 10 | `token_policies` 里写了不存在的 policy 名 | Vault **接受**，token 签发成功，那部分权限静默为空 | 先创建 policy 再引用；缺失表现为运行时 403 |
| 11 | `steps.<id>.outputs.vault_token` 需要 `exportToken: true` | 下游脚本报 `VAULT_TOKEN is required`，像权限问题 | 需要 token 的 job 显式开启 |

### Ansible / Docker

| # | 陷阱 | 症状 | 修法 |
|---|---|---|---|
| 12 | **ansible 0 主机命中仍 exit 0** | 假绿：job ✓ 但什么都没部署 | `setup-deployment-runner`（ping 断言） |
| 13 | role 依赖写 `docker` 会命中 `roles/docker/`（**命名空间目录，不是角色**） | 展开 2 个任务而非 20 个，**不报错** | 写全 `vhosts/docker`；用 `--list-tasks` 验证任务数与顺序 |
| 14 | **bind mount 源路径不存在时 Docker 自动创建目录** | `/root/.docker/config.json: is a directory`；私有镜像静默拉不动，容器仍 healthy | mount 前先确保文件存在（`docker login`），并断言 `stat.isdir == false` |
| 15 | Jinja 默认 `Undefined` 不抛错，缺键渲染成空串 | `console-uat.` 这类"看起来已渲染"的值 | 渲染器入口对必需变量显式断言；本地用 `StrictUndefined` 复核模板 |
| 16 | 空口令/缺证书**不会让任何东西崩溃** | postgres 正常启动、服务正常监听、部署报绿，第一次登录才暴露 | 断言放在写任何文件**之前**，必须让 play 失败 |

### Terraform

| # | 陷阱 | 症状 | 修法 |
|---|---|---|---|
| 17 | 资源名含随触发路径变化的变量，却共用同一 state | **销毁一台再新建一台**，IP 漂移 | 拼进资源名的变量必须在所有命中该 state 的路径上取值一致 |
| 18 | Vultr **不支持原地降配** | `plan` 能过，`apply` 报 `does not support in-place VPS downgrades` | 走 `action=resize` 的快照-验证-接管流程 |

### 密钥

| # | 陷阱 | 修法 |
|---|---|---|
| 19 | **gitleaks 版本差异会漏报**。CI 8.21.2 与本地 8.30.1 在同一份历史上各自漏掉对方发现的东西 | CI 版本升到与本地一致后重扫全部仓库 |
| 20 | 净化历史 ≠ 凭据已安全。已 clone 的副本仍持有密钥 | **先轮换，再净化**。见 [密钥泄露台账](2026-07-24-secret-leak-ledger.md) |

---

## 1. 五个业务仓 CI 收敛为 prep + build

### 目标

`accounts`、`billing-service`、`portal`、`docs`、`postgresql` 五个仓库**只跑 CI**：
构建镜像并按契约打 tag 推到 GHCR。**不部署**。

### 为什么

边界（[DELIVERY-MANIFEST.md](../domains/DELIVERY-MANIFEST.md)）：

| 环节 | 归属 |
|---|---|
| 构建镜像 | **业务仓 CI** |
| 部署容器化应用 | **GitOps 侧**：Doco-CD（预留 K3s/K8s）从 gitops 仓拉取 |
| 主机初始化 / 非容器化服务 | SSH + Ansible（`platform-ops.yaml` → playbooks） |

这些仓库里残留着已被移除的 deploy job 的碎片——host 解析、`RUN_APPLY`、以及
"两者不一致就失败"的守卫。守卫在 `prep` 阶段触发，于是**镜像根本没被构建过**。
`ghcr.io/x-evor/accounts` 查不到 package 就是这个原因，不是凭据问题。

### 当前状态（2026-07-25）

五个仓库都在 `fix/ci-vault-and-build*` 分支上，deploy 残留已清零，PR 均已开：

| 仓库 | PR | 分支 |
|---|---|---|
| accounts | [#37](https://github.com/ai-workspace-services/accounts/pull/37) | `fix/ci-vault-and-build` |
| billing-service | [#14](https://github.com/ai-workspace-services/billing-service/pull/14) | `fix/ci-vault-and-build-2` |
| docs | [#5](https://github.com/ai-workspace-services/docs/pull/5) | `fix/ci-vault-and-build` |
| portal | [#112](https://github.com/ai-workspace-services/portal/pull/112) | `fix/ci-vault-and-build` |
| postgresql | [#14](https://github.com/ai-workspace-infra/postgresql.svc.plus/pull/14) | `fix/ci-vault-and-build` |

### 每个仓库的验收

**① 触发路径矩阵**（不设任何 host 变量，三条路径都必须 rc=0）：

```bash
cd <repo>
for ev in "push:refs/heads/main" "push:refs/tags/v1.2.3" "pull_request:refs/pull/1/merge"; do
  GITHUB_EVENT_NAME="${ev%%:*}" GITHUB_REF="${ev#*:}" \
  GITHUB_OUTPUT=/tmp/o bash scripts/github-actions/resolve-pipeline-flags.sh >/dev/null 2>&1
  echo "$ev -> rc=$? $(grep -E 'deploy_env|push_image|push_latest' /tmp/o | tr '\n' ' ')"
done
```

期望：三行全部 `rc=0`，且 `pull_request` 下 `push_image=false`。

**② 镜像 tag 符合[跨仓契约](../domains/IMAGE-TAG-CONTRACT.md)**：

| 触发 | 必须产出 |
|---|---|
| `v*` tag | `v1.2.3`（原样） |
| `release/*` | `release-1.4`（`/` 非法，规范化为 `-`） |
| `main` | `latest` |
| **任意构建** | `sha-<40 位全长>` |

最后一条无条件。UAT 的 `deploy_tag` 恒为 `latest`，所以 **`main` 必须在
`push.branches` 里**——缺了它 `latest` 永不刷新，UAT 部署报绿却一直是旧镜像。

**③ 镜像真的存在于 GHCR**（这一步不能跳过——前两步只证明 CI 逻辑对）：

```bash
gh api "orgs/<org>/packages/container/<pkg>/versions" \
  -q '.[].metadata.container.tags[]?' | sort -u
```

需要 `read:packages` scope。看不到 `latest` 就是没推成功。

### 分派给 subagent 时

每个 agent 一个仓库，prompt 必须自包含：仓库路径、上面的验收命令、以及
§0 里 #1#2#3#5 四条（GitHub Actions 那几条最容易再次踩到）。

---

## 2. 补全 gitops/compose 的四个业务域

### 目标

`compose/<domain>/` 覆盖四个域，**每个域自带 postgresql + stunnel-server +
stunnel-client**：

| 域 | 现状 |
|---|---|
| `web-saas` | 已有 `accounts` / `billing` / `console-assets` / `console` / `caddy`；**缺 postgresql + stunnel** |
| `ai-workspace` | 未创建 |
| `agent-proxy` | 未创建 |
| `open-platform` | 未创建 |

四个域的服务清单见 [DELIVERY-MANIFEST.md](../domains/DELIVERY-MANIFEST.md)。

### 硬约束（照抄现有 web-saas 的形态，不要自创）

1. **所有 bind mount 写绝对路径。** Doco-CD 每次部署把仓库全新 clone 到临时目录
   再跑 `docker compose`——相对路径会解析到那个 clone 里，而证书和配置不在仓库里
   （也不该在），于是**挂载出空目录而不是报错**（§0 #14 同源）。

2. **镜像 tag 只出现在 `.env.<env>`**，compose 里一律 `${X_IMAGE:?set in .env.<env>}`。
   `:?` 让缺失时立刻失败而不是拼出一个 `image:` 空值。

3. **主机侧输入由 Ansible 从 Vault 渲染**，路径 `/etc/xcontrol/<domain>/`：

   ```
   secrets.env      0600   各服务以绝对路径 env_file 读取
   config/          0755   postgresql.conf / stunnel-{server,client}.conf / <app>.yaml
   certs/           0700   ca-cert.pem / server-cert.pem / server-key.pem(0600)
   Caddyfile        0644   compose 里那个 caddy 容器用的
   ```

   参考角色：`playbooks/roles/vhosts/web_saas_host_config/`。新域按它复制一份，
   **不要把口令或证书放进 gitops 仓**。

4. **网络名统一 `docker_shared_network`**（原 `cn-toolkit-shared` 已改名）。
   compose 声明它，Ansible 侧幂等创建。

5. **stunnel 的连接拓扑**：`stunnel-client` → `stunnel-server` → `postgres`，
   三者都在 compose 网络内，**用服务名而非主机地址**。业务服务连库走
   `stunnel-client:5432`。端口对应关系必须与 `.env.<env>` 里的
   `STUNNEL_ACCEPT_PORT` 一致。

### 验收

**① compose 语法与变量完整性**：

```bash
cd compose/<domain>
docker compose --env-file .env.uat config >/dev/null && echo ok
```

**② 每个 `MANAGED_IMAGES` 变量都在 `.env.<env>` 里声明。**
发布脚本（`playbooks/.github/scripts/domain-cd-publish-tag.sh`）**拒绝**写入未声明的
变量，也拒绝创建缺失的 `.env` 文件——那等于凭空发明一套部署声明。

**③ 域 wrapper 声明 `managed_images`**：
`playbooks/.github/workflows/<domain>-domain-cd.yaml` 里显式列出该域随发布推进的
镜像变量。基础组件（postgres / stunnel / caddy）**不列**——它们钉在验证过的版本上
单独升级。

---

## 3. UAT 端到端：IaC → Doco-CD → web-saas → DNS

### 目标

1. `deploy_web_saas` 成功部署 UAT
2. 部署完成后 DNS 解析正常发布

### 链路形状

```
platform-ops.yaml
  resize        (action=resize 时才跑)
  provision     Terraform apply → CMDB/inventory → 初始化数据库凭据
  deploy_base   Bootstrap Node：装 Docker、渲染 /etc/xcontrol/、装 Doco-CD
  deploy_*      委派 playbooks 的域 CD → 把 deploy_tag 写进 gitops 的 .env.<env>
                                        ↓
                  主机上 Doco-CD 每 60s 轮询 gitops，拉到新 commit 后收敛
  switch_dns    Cloudflare A 记录切换（environment: production，需人工审批）
```

**部署动作本身是"往 gitops 推一个 commit"**，不是 SSH 到主机跑 compose。
git 提交历史即部署历史。

### 触发命令

```bash
gh workflow run platform-ops.yaml --repo ai-workspace-infra/platform-ops-toolkit --ref main \
  -f runner_type=ubuntu-latest \
  -f source_host=install.svc.plus \
  -f source_domain_base=svc.plus \
  -f target_domain_base=onwalk.net \
  -f run_infrastructure=true \
  -f run_application_deploy=true \
  -f target_domains=web-saas \
  -f cloud_provider=vultr-vps \
  -f instance_plan=4C8G \
  -f action=deploy \
  -f confirm_dns_switch=true \
  -f vault_env_path=uat
```

> **`instance_plan` 必须与主机现状一致。** 填一个更小的规格会触发降配，而 Vultr
> 不支持原地降配（§0 #18）——Terraform 会在 plan 之后失败，什么都不做。查现状：
> `.env` 无关，直接看上一次 run 的 Terraform 输出，或 `vultr-cli instance list`。

### 验收（**必须做实机验证，run 报绿不算**）

这条链路的教训就是假绿。三层都要查：

**① 流水线层**：

```bash
gh run view <id> --repo ai-workspace-infra/platform-ops-toolkit \
  --json jobs -q '.jobs[]|"\(.conclusion//.status)  \(.name)"'
```

`Bootstrap Node` 与 `Deploy Web SaaS Services` 必须是 `success`，**不是 `skipped`**。
skipped 与"本来就没请求"同形，是 §0 #1 的表现。

**② gitops 层**——发布是否真的产生了 commit：

```bash
gh api repos/ai-workspace-infra/gitops/commits \
  -q '.[0] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"'
```

期望看到 `deploy(web-saas/uat): <tag>`。**若 tag 未变化，发布脚本会输出
"No image tag changed; nothing to publish" 并 exit 0**——这时 Doco-CD 不会收到
新 commit，但它在首次部署时会自行拉取一次，所以这不必然是失败。

**③ 主机层**——容器真的起来了：

```bash
ssh root@<uat-host> 'docker ps --format "{{.Names}} | {{.Status}} | {{.Image}}"'
ssh root@<uat-host> 'docker logs doco-cd 2>&1 | tail -20'
```

只有 `doco-cd` 一个容器 = 栈没起来。**去看 doco-cd 日志**，它会明确说原因。
已知一种：

```
failed to pull images: error from registry: unauthorized
```

→ `/root/.docker/config.json` 是空目录，缺 GHCR 凭据（§0 #14）。

**④ DNS 层**：

```bash
dig +short console-uat.onwalk.net
curl -sSI https://console-uat.onwalk.net | head -3
```

解析到 UAT 主机 IP，且 HTTPS 能握手（Caddy 需要先签发证书，首次可能要等几十秒）。

### 已知前置条件

| 前置 | 状态 | 缺失时的表现 |
|---|---|---|
| `kv/data/CICD/uat` 的 `GITOPS_TOKEN` | ✅ 已配置 | 发布步骤指名道姓报错 |
| `kv/data/CICD` 的 `GHCR_USERNAME`/`GHCR_TOKEN` | 需确认 | Doco-CD 日志 `unauthorized`，容器仍 healthy |
| `kv/data/WEB_SAAS` 的 stunnel 证书三件套 | 需确认 | 角色断言失败（这是**期望行为**，见 §0 #16） |
| GHCR 上 `accounts`/`billing`/`console` 的 `latest` | ❌ **未发布** | Doco-CD `unauthorized` 或 `manifest unknown` |

**最后一行是任务 3 的真实阻塞点，且依赖任务 1 完成。** 五个仓库的 CI 从未成功
推过镜像——Doco-CD 就算凭据齐全也拉不到东西。

---

## 交接检查点

接手时按顺序确认：

```bash
# 1. 三个仓库的 main 是否都是最新
for r in platform-ops-toolkit playbooks; do
  echo "$r: $(gh api repos/ai-workspace-infra/$r/commits -q '.[0].sha[0:7]')"
done

# 2. 有没有未合的关键 PR
for r in ai-workspace-infra/platform-ops-toolkit ai-workspace-infra/playbooks \
         ai-workspace-infra/gitops; do
  echo "=== $r"; gh pr list --repo $r --json number,title -q '.[]|"  #\(.number) \(.title)"'
done

# 3. 守卫脚本是否通过
cd platform-ops-toolkit && python3 scripts/ci/workflow_gating_verify.py

# 4. 上一次 UAT run 停在哪一层
gh run list --repo ai-workspace-infra/platform-ops-toolkit \
  --workflow platform-ops.yaml --limit 1 --json databaseId,conclusion
```

## 相关文档

- [领域交付清单](../domains/DELIVERY-MANIFEST.md)——四个域与交付边界
- [镜像 Tag 跨仓契约](../domains/IMAGE-TAG-CONTRACT.md)——CI 必须产出哪些 tag
- [UAT 解阻记录](2026-07-23-uat-web-saas-deploy-unblocking.md)——前七层缺陷的逐层过程
- [密钥泄露台账](2026-07-24-secret-leak-ledger.md)——待轮换清单
- skill `engineering-standards/ci-cd-workflow-spec` §10——job gating 必须可falsify
- skill `engineering-standards/multi-environment-delivery-and-release` §2.2/§5——KV 三层模型、文档只引用 KV path
