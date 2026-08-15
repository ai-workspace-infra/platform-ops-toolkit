# UAT web-saas 部署解阻 —— 逐层记录

目标（`/goal`）：

1. `deploy_web_saas` 能顺利完成部署 UAT 环境
2. 部署完成后 DNS 解析能正常发布

主机 `console-uat.onwalk.net` / `167.179.64.91`（Vultr nrt, Debian 13, vc2-4c-8gb）。

## 为什么值得单独记一份

这条链上的缺陷有一个共同形态：**每一个都被前一个掩盖着**。修掉第 N 个之前，
第 N+1 个连"发生"的机会都没有 —— 所以它不是一次排查，而是七次，每次都要
重新判断"这次红的是新东西还是旧东西没修干净"。

更麻烦的是前几层**根本不红**。假绿与 skip 在 run summary 里和"本来就没请求"
完全同形，靠 review 看不出来。这也是为什么中途要停下来做一个断言脚本，
而不是继续手工往下查。

## 逐层

| # | 缺陷 | 症状 | 修复 |
|---|---|---|---|
| 0 | deploy 脚本相对路径错，`ansible` 0 主机命中仍 exit 0 | **假绿**：job ✓ 但什么都没部署 | 还原按服务序列 + `setup-deployment-runner` Ansible target assertion |
| 1 | 9 处 `if: >-` 折叠标量在 `${{ }}` 内保留换行 | 表达式永不求值，全部 job skip | #88 统一缩进 |
| 2 | skip 沿 `needs` 链传递，`deploy_base` 缺 `always()` | 条件每个操作数都成立，job 仍 skip | #90 |
| 3 | 2 个脚本 git mode `100644`，被 `run:` 裸调用 | exit 126 Permission denied，日志只有 env 块 | #93 |
| 4 | `github-actions-playbooks-*` 绑错 `repository` claim | 四个域 job 一跑就 Vault 认证失败 | #97 |
| 5 | Doco-CD 无条件要求 git access token | `[ERROR]: Set DOCO_CD_GIT_ACCESS_TOKEN` | playbooks#179 + #98 |
| 6 | Doco-CD 角色不安装 Docker Engine | `[Errno 2] No such file or directory: b'docker'` | 本次 |

### #2 是怎么定位的

`resize` 在非 resize 触发时被跳过，`provision` 只因自身 `if` 以 `always()`
开头才运行。**这个 skip 会沿 `needs` 链继续传递，而 `always()` 只为携带它的
那个 job 挡一次。**

之前几轮一直在审操作数，因为条件看起来对 —— 它确实是对的。run 30011277664 里：

- `run_application_deploy` = `'true'`（gate 在这个值上的 step 18 成功执行）
- `terraform_action` = `'apply'`
- `count` / `hosts` = `1` / `["console-uat.onwalk.net"]`

**判别方法**：step 层 gate 在 `steps.<id>.outputs.X` 上跑了、job 层 gate 在
`needs.<job>.outputs.X` 上却跳了 → 值是好的、传递是坏的。等价地：恰好带
`always()` 的 job 都跑了、不带的都跳了 → 被测的不是条件。

`switch_dns` 是唯一跑起来的 job，也是唯一条件里本就带 `always()` 的 —— 就是
这个对照定位了它。

修复要 `always()` **加** 显式 `needs.<up>.result == 'success'`：只加前者会让
上游真失败时反而照跑。

### #4：跨仓 `uses:` 的 `repository` claim

`github-actions-playbooks-*` 这三个 role 只用于 `platform-ops.yaml` 跨仓调用
playbooks 的域 CD。这种调用下 OIDC 的 `repository` claim 是**运行所属的仓库**
（调用方 toolkit），不是持有可复用 workflow 的 playbooks。绑成 playbooks 就
永远匹配不上。被调用方的身份由 `job_workflow_ref` 钉住 —— GitHub 引入这个
claim 正是为了可复用 workflow。

**至今没暴露，是因为这四个 job 从来没运行过**（#90 之前全被 skip）。

### #5：不存在的凭据

`ai-workspace-services/*` 全是公开仓库，Doco-CD 拉取不需要凭据。那条无条件
断言本身就是缺陷，不是待补齐的前置条件。

中途我一度往反方向修（去 Vault 取这个 token），结果**更糟**：`vault-action`
遇到缺失的键直接报错，失败点从 Ansible 断言前移到了 `Load Vault secrets`。
已由 #98 撤回。教训：报错说"缺 X"时，先问"X 应该存在吗"。

### #6：Doco-CD 不安装 Docker

角色本身就是"渲染 compose 再拉起来"，没有 Docker Engine 一步都走不了。
写成 `meta/dependencies` 而非在 playbook 里多列一个 role —— 这条约束属于
角色本身，无论哪个 playbook 引用它。

**踩到一个静默解析陷阱**：依赖写 `docker` 也能解析成功，但会命中
`roles/docker/` —— 那是个命名空间目录不是角色，展开后只有 2 个任务而不是
20 个，**且不报错**。必须写 `vhosts/docker`。校验：

```bash
ansible-playbook -i inv setup-Doco-CD.yaml --list-tasks
```

确认 20 个 `vhosts/docker :` 任务全部排在第一个 `Doco-CD :` 任务之前。

## 固化：`workflow_gating_verify.py`

查到第 3 层时停下来做的断言脚本（`scripts/ci/`，接入 `validate-release-pr.yml`）。
五条检查各自对应上表中真实发生过的一次缺陷：

| 检查 | 对应 |
|---|---|
| C1 | 折叠标量吞表达式（#1） |
| C2 | skip 越过 `always()` 传递（#2） |
| C3 | `always()` 无 result 断言（顺带在 `iac-pipeline-multi-cloud-master.yaml` 抓到 2 个真的） |
| C4 | `needs.<x>` 未在 `needs:` 中声明 |
| C5 | 裸调用脚本缺 exec 位（#3） |

**变异验证过**，不是写完就算：摘掉 `deploy_base` 的 `always()` → C2 触发、
exit 1；还原 → 9 个 workflow 全过。

C3 抓到的两个是真缺陷：`account` / `resources` 把
`needs.prepare-matrix.outputs.*_components` 传进可复用 workflow，却在
`always()` 下不断言 `prepare-matrix` 成功 —— 它一失败 `components_json` 就是
空，下游 matrix 遍历空集合然后**报成功**。

## 相关规范

- skill `engineering-standards/ci-cd-workflow-spec` §10（skills#26）
- [镜像 Tag 跨仓契约](../domains/IMAGE-TAG-CONTRACT.md)
- [领域交付清单](../domains/DELIVERY-MANIFEST.md)

## 待办

- [ ] #6 合入后跑通 `deploy_web_saas`
- [ ] DNS 发布验证（`switch_dns` 挂 `environment: production`，需人工审批）
- [ ] 各服务仓 tag 契约落地（accounts / docs / portal / postgresql 分支已就绪）
