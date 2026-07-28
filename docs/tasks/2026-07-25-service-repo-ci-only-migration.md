# 任务规划:业务仓库收敛为纯 CI(交接文档)

## 背景与决策

`ai-workspace-services/accounts` 的 main 分支自 2026-07-23 起持续构建失败:

```
resolve-pipeline-flags: no target host for deploy env 'uat'.
Set the UAT_TARGET_HOST repository variable (main deploys to uat).
```

追查发现 pipeline 只剩 `prep` + `build` 两个 job —— **deploy job 早已被移除**,
但 host 解析(`TARGET_HOST`)、`RUN_APPLY` 标志、以及"两者不一致就失败"的
守卫全都是死代码,却仍在 `prep` 阶段卡住构建。结果是**镜像从未被推送过**
(`ghcr.io/x-evor/accounts` 查不到 package,不是权限问题,是压根没发布过)。

这直接阻塞了 `platform-ops-toolkit` 那条 UAT 部署链路的目标:即使 Doco-CD、
GHCR 凭据、DNS 全部修好,Doco-CD 轮询到的镜像也不存在。

### 用户已确认的架构边界

> 使用了 gitops + Doco-CD 或者 gitops + K3s/K8s,业务应用部署就不用
> SSH/Ansible 到目标主机部署。SSH/Ansible 到目标主机部署只是为了初始化
> gitops + Doco-CD 或者 gitops + K3s/K8s。其他非容器的还是保持 SSH/Ansible
> 到目标主机使用 playbook 部署。
>
> accounts/portal/billing-service 这三个仓库,包括其他仓库,都是支持
> gitops + Doco-CD 和预留 gitops + K3s/K8s,但默认不启用部署。
> **业务代码仓库默认只启用 CI,不单独启用 CD。**

即:

| 场景 | 部署方式 |
|---|---|
| 容器化业务服务(accounts/billing/console/portal 等) | gitops + Doco-CD(或未来 K3s/K8s),**不用** SSH/Ansible |
| 非容器化服务、主机初始化 | 保持 SSH/Ansible + playbook |
| 业务代码仓库自身 CI | **只构建推送镜像,不触发部署** |

## 已完成

### `ai-workspace-services/accounts`

PR: [#36](https://github.com/ai-workspace-services/accounts/pull/36)(待合)

- 移除 `scripts/github-actions/resolve-pipeline-flags.sh` 里的
  `DEFAULT_TARGET_HOST` / `PROD_TARGET_HOST` / `UAT_TARGET_HOST` /
  `RUN_APPLY`、host 解析逻辑、以及那道"push_image && run_apply && 无 host
  就失败"的断言
- 移除 `.github/workflows/pipeline.yml` 里对应的 env 块、`prep` job 的
  `target_host`/`run_apply` outputs、`workflow_dispatch` 的
  `target_host`/`run_apply` 两个输入
- **镜像 tag 行为未动**,仍符合 `IMAGE-TAG-CONTRACT.md`
- 验证(不设任何 host 变量):

  ```
  push main       -> deploy_env=uat  push_image=true  push_latest=true
  push v1.2.3     -> deploy_env=prod push_image=true  push_latest=false
  pull_request    -> deploy_env=uat  push_image=false push_latest=false
  ```

## 待办:另外四个仓库

工作目录:`/Users/shenlan/workspaces/ai-workspace-service/{billing-service,docs,portal,postgresql}`

**先查后改** —— 每个仓库的直连部署实现方式不一定相同,accounts 的模式
(独立 flags 脚本 + `RUN_APPLY` 布尔)只是其中一种。核查步骤:

1. `grep -rln "TARGET_HOST\|RUN_APPLY\|ansible-playbook\|ssh .*deploy" .github/ scripts/`
2. 确认该 repo 的 workflow 是否真的有一个会 SSH/Ansible 到主机的 deploy job
   (不是所有仓库都有 —— 例如 `docs`/`postgresql` 可能从一开始就只是 CI Build,
   需要先确认再动)
3. 若有,判断能否像 accounts 一样整段移除;若部署逻辑与构建逻辑深度耦合
   (例如同一个 job 里既 build 又 deploy),需要拆分而非删除
4. 保留的部分:镜像/chart 构建、推送 GHCR、`IMAGE-TAG-CONTRACT.md` 约定
   的四种 tag(`v*`/`release/*`/`latest`/`sha-<40位>`)
5. 每个仓库单独开 PR,标题风格参考 accounts 的
   `ci: drop the direct-deploy remnant that blocked every main build`

### `billing-service`

- 已知线索:`scripts/github-actions/resolve-deployment-profile.sh` 存在,
  且 `release-traceability.yml` 里 `build` job 后有
  `scripts/github-actions/deploy-billing-service.sh`,曾报
  `DATABASE_URL: DATABASE_URL is required`
- 与 accounts 不同:这里的 deploy 脚本**紧跟在 build job 之后**,不是独立
  job——需要先读 `release-traceability.yml` 全文确认能否干净拆分
- 用户本地这个仓库还有一批**未提交的其他工作**(`feat/env-profile-config`
  分支,`internal/service/reconcile.go` 等一大批文件),**动手前必须
  `git status` 确认不会踩到那些改动,必要时先问用户还是先 stash**

### `portal`

- 已知线索:`Resolve Inputs` 步骤读 `UAT_TARGET_HOST`/`DEV_TARGET_HOST`/
  `PROD_TARGET_HOST`,报 `UAT_TARGET_HOST must be configured before
  deploying uat.`
- 未定位到具体脚本文件(此前 `find` 没找到 `*pipeline-flags*`/
  `*resolve-deployment-profile*`,说明命名不同,需要重新
  `grep -rn "UAT_TARGET_HOST" .github/ scripts/` 定位)

### `docs`

- 尚未核查是否存在直连部署逻辑。先确认它是否真的有 deploy job,
  还是从一开始就只是 CI Build(参照 `IMAGE-TAG-CONTRACT.md` 里
  `docs/build-push-ghcr-image.yml` 只有 `workflow_call`/`workflow_dispatch`,
  没有独立 push 触发 —— 可能本来就没有直连部署这回事)

### `postgresql`(即 `ai-workspace-infra/postgresql.svc.plus`)

- 尚未核查。这是基础设施仓库不是业务服务仓库,直连部署的可能性和形态
  可能与另外三个不同(它产出的是 postgres/stunnel 镜像与 chart,不是
  业务容器),需要单独判断"CI-only"这条原则是否同样适用,还是它本来就
  只是镜像/chart 构建

## 相关文档

- [跨仓契约:镜像 Tag](../domains/IMAGE-TAG-CONTRACT.md) —— 四个仓库改造后
  仍必须遵守的 tag 规则,不要在清理直连部署时误改
- [领域交付清单](../domains/DELIVERY-MANIFEST.md) —— CI Build 与 CD 的
  边界划分,这次改造是把这条边界从"文档约定"落成"代码里已经没有违反它的
  可能"
- [UAT web-saas 解阻记录](2026-07-24-uat-web-saas-deploy-unblocking.md)——
  为什么这件事现在是阻塞项(Doco-CD 已能正确轮询部署,但业务仓库从未
  推送过镜像)

## 2026-07-27 补充

`platform-ops-toolkit/.github/workflows/daily-main-snapshot.yaml` 里的跨仓库快照
需要单独的 `CROSS_REPO_GH_TOKEN`，不能再依赖本仓库的 `GITHUB_TOKEN` 去写
`ai-workspace-infra/artifacts` 等其他仓库。否则 `gh api --method POST repos/.../git/refs`
会在 GitHub Actions 里直接返回 `403 Resource not accessible by integration`。

### 推荐配置

`CROSS_REPO_GH_TOKEN` 建议直接用 **fine-grained PAT** 来配。

#### 怎么创建

1. 打开 GitHub 头像菜单。
2. 进入 `Settings`。
3. 左侧点 `Developer settings`。
4. 进入 `Personal access tokens`。
5. 选择 `Fine-grained tokens`。
6. 点 `Generate new token`。

#### 怎么填

1. `Token name`：比如 `platform-ops-toolkit-cross-repo`
2. `Expiration`：建议别选无限期，选一个明确到期时间
3. `Resource owner`：选能访问目标仓库的那个组织
4. `Repository access`：只选需要被写入的目标仓库，比如 `ai-workspace-infra/artifacts`
5. `Permissions`：
   - `Contents: Read and write`
   - 如果还要跨仓库触发 workflow，再加 `Actions: Read and write`

GitHub 官方说明，fine-grained PAT 可以限制到单个组织、单个或少量仓库，并赋予细粒度权限；这正适合这个场景。默认的 `GITHUB_TOKEN` 只适合当前仓库，不能拿去写别的仓库。来源：[GitHub PAT 管理文档](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) 和 [fine-grained PAT 权限说明](https://docs.github.com/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)

#### 怎么放进仓库

1. 打开 `platform-ops-toolkit`
2. 进入 `Settings -> Secrets and variables -> Actions`
3. 新增 secret，名字填 `CROSS_REPO_GH_TOKEN`
4. 值粘贴刚创建的 fine-grained PAT

#### 注意两点

1. 如果组织启用了 PAT 限制，可能需要先审批这个 token 才能访问组织仓库。
2. 这个 token 只要能写目标仓库就够了，不要给过大的 repo 范围。

#### GitHub App 方案

GitHub App 也可以直接安装到个人账户或组织上。官方文档说明，App 可以安装在
`personal account` 和组织上，并按仓库粒度授予权限。

1. 打开 GitHub 头像菜单。
2. 进入 `Settings`。
3. 左侧点 `Developer settings`。
4. 进入 `GitHub Apps`。
5. 点 `New GitHub App`。
6. `GitHub App name` 随便取一个能看懂的名字，比如 `platform-ops-toolkit-bot`。
7. `Homepage URL` 可以填仓库主页。
8. `Webhook` 如果这个 App 只用来做 CI token vending，可以先不启用 webhook。
9. 在权限里至少给 `Repository permissions` 下的：
   - `Contents: Read and write`
   - 如果还要触发 workflow，再加 `Actions: Read and write`
10. 创建完成后，记下 `Client ID`，下载并保存 `Private key`。
11. 去 `Install App`，安装到需要写入的目标账户上。
   - 如果是组织，选组织账号并勾选需要的仓库。
   - 如果是个人账户，选个人账号并勾选需要的仓库。
12. 把 `Client ID` 和 `Private key` 存进 `platform-ops-toolkit` 的 Actions 配置，
   名字建议用 `CROSS_REPO_GH_APP_CLIENT_ID` 和 `CROSS_REPO_GH_APP_PRIVATE_KEY`。

这个 workflow 现在走 GitHub App 安装令牌方案时，会按目标 owner 分组换 token，
所以组织仓库和个人账户仓库都能单独安装、单独授权，不需要让一个 token 横跨多个 owner。

这个 workflow 只读取 `CROSS_REPO_GH_TOKEN` 或 GitHub App 相关 secrets，不会再回退到默认 `GITHUB_TOKEN`。

## 验证方式(每个仓库通用)

改完后本地跑一遍(不设任何 host 相关变量),确认三条触发路径都不再要求
host:

```bash
GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main <flags-script>
GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.2.3 <flags-script>
GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/9/merge <flags-script>
```

三次都应正常输出,不因缺少 `*_TARGET_HOST` 而 `exit 1`。
