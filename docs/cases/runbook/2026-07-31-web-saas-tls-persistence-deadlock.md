# 案例：web-saas 泛域名证书从未真正复用过（2026-07-28 ~ 2026-07-31）

## TL;DR

`*.onwalk.net` 的 ACME DNS-01 泛域名证书链路从上线第一天起就没有真正“复用”
过：每一次重建都重新触发签发，反复撞上 Let's Encrypt 的 5 次/周限流。表面
症状换了三次皮（数据库建不出来 → 证书压根没签出来 → 证书签出来了但存不进
Vault → 存进 Vault 了但读不出来），但四层根因其实是**同一个反模式的四个变
体**：*用“下游是否已经成功”去判断“上游该不该执行”*，而下游的成功恰恰依赖
上游先执行。

修复分五个 PR 落地：platform-ops-toolkit#164/#165（建库死锁）、#170（每次
部署都验收）、#171/#172（证书持久化接线）、#213（备份死锁 + staging 证书
误存）、#214（取回判据用错字段）。本文档把完整链路记下来，重点是“如何避免”
——这类反模式会在任何“先决条件 A → 执行 B → 验收 C → 反哺 A”的循环里复现，
不限于证书。

## 背景

- 目标：`web-saas` 域的每次主机重建都应当在 ~10 分钟内自动起来，且证书在
  90 天有效期内应当被**复用**而不是每次重签。
- 手段：Caddy 走 ACME DNS-01（Cloudflare），签一张 `*.<domain>` 泛域名证书；
  证书材料备份进 Vault `kv/data/CICD/domains/<domain>`（三环境共享，见
  [`2026-07-29-domain-wildcard-tls-reuse.md`](../../tasks/2026-07-29-domain-wildcard-tls-reuse.md)），
  下次重建时先从 Vault 恢复，恢复成功则 Caddy 完全不触碰 ACME。
- 症状最早的表现是 UAT 环境重建后长期 502 / TLS 握手失败，日志里反复出现
  `HTTP 429 too many certificates already issued for this exact set of
  identifiers`。

## 根因链：四层反模式，逐层剥开

每一层都是“看似生效，实际从未被触发过”，且都是**下一次重建才会暴露上一层
的修复是否真的生效**——这是本案例耗时长的主要原因：每个修复都要等一次真实
的 destroy + rebuild 才能验证，而每次验证又会消耗当天的限流额度。

### 第 1 层：建库 job 排在健康检查之后，形成死锁

**现象**：`accounts` 容器反复重启，`relation "users" does not exist`。

**根因**：`initialize_web_saas_databases`（建库）的 `needs` 里包含
`deploy_web_saas`（这个 job 内含健康检查）。而 `accounts` 没有数据库就连不
上、健康检查就永远过不去、`deploy_web_saas` 就永远不会成功、建库 job 就永
远不会运行。两个 job 互相等对方先成功。

**为什么直到这时才暴露**：`deploy_web_saas` 原本只做“validate + confirm
pull-only”，从不检查容器是否真的健康——直到给它加上真实的 endpoint 探测
（第 2 层），这个死锁才从“理论上存在”变成“每次重建都触发”。

**修复**：`platform-ops-toolkit#164` / `#165`——把建库挪到健康检查**之
前**，改成 `initialize_web_saas_databases` 只依赖 `deploy_base`，
`deploy_web_saas` 反过来依赖建库完成。

> **同一趟排查里还复现了一次陷阱 #11**：给 `deploy_base` 加恢复/备份步骤
> 时（第 3 层），发现它的 `hashicorp/vault-action` 步骤没开
> `exportToken: true`，导致 `steps.vault.outputs.vault_token` 恒为空，
> 报错与
> [`2026-07-25-delivery-chain-workplan.md`](../../tasks/2026-07-25-delivery-chain-workplan.md)
> 陷阱 #11 完全一致——`VAULT_TOKEN is required`，读起来像权限问题，实际是
> 一个漏加的配置项。已知陷阱在同一个仓库、间隔几天后又踩了一次，说明“已
> 知陷阱表”本身需要变成可执行的 CI 检查，而不能只停留在文档里靠人记住
> （见下方“如何避免”第 1 条）。

### 第 2 层：健康检查只在“切流量”时跑，常规部署路径上形同虚设

**现象**：即使容器全部健康，流水线也不会在常规部署里验证任何东西——它默认
就是绿的。

**根因**：观测/健康检查步骤挂在 `switch_dns` job 里，而 `switch_dns` 只在
`confirm_dns_switch == true` 时才跑，这个开关默认 `false` 且文档写着“仅真
实灾备启用”。也就是说，日常部署这条检查**一次都不会执行**。

**修复**：`platform-ops-toolkit#170`——新增 `observe_web_saas` job，不看
`confirm_dns_switch`，只要部署跑了就验收，并用 `--resolve` 把域名钉到本次
CMDB 产出的 IP 上（DNS 是否已切换不影响验收结果）。

### 第 3 层：证书备份挂在健康检查之后且无条件跳过，与第 1 层同构的死锁

**现象**：Vault 里那条证书记录被创建了，但字段全是空的；每次重建 Caddy 都
重新走 ACME，反复撞 429。

**根因**：备份步骤排在 `observe_web_saas` 的健康检查**之后**，且没有
`if: always()` 之类的条件——一旦检查失败（这几乎是必然的：证书不在 Vault
时，Caddy 只能等 ACME，而这个环境已经处在限流窗口里），备份步骤直接被
skip。这与第 1 层是**完全相同的结构**：

```
证书不在 Vault → Caddy 只能找 ACME 签 → 撞 429 拿不到证书
  → observe 因为没有 TLS 而失败 → 备份步骤被 skip（无 if 条件）
  → 证书还是不在 Vault → 下一轮重复
```

**关键教训**：加上“成对”的另一条防线之前，单独修这一层是危险的——见下一
层。

**修复**：`platform-ops-toolkit#213`——备份步骤改成 `if: !cancelled()`，
与站点是否健康解耦：“证书能不能复用”和“服务起没起来”是两件事，不该用同一
个信号门控。

### 第 4 层（与第 3 层成对）：备份必须只认生产签发的证书，否则会把“毒证书”存进共享记录

**现象**（如果只做第 3 层的修复而不做这一层）：Let's Encrypt 生产限流期
间，Caddy 会退而使用 **staging** CA 签出一张证书——功能完全正常，但由一个
浏览器不信任的根签发。第 3 层的无条件备份会把这张证书存进
`kv/data/CICD/domains/onwalk.net`，而这条记录是 **sit/uat/prod 三个环境共
享**的。

**后果**：下一次任何环境重建，都会从 Vault “成功恢复”一张没人信任的证书，
日志上完全看不出异常——比原来“没有证书”的状态更难排查，因为链路表面上是
通的。

**修复**：`platform-ops-toolkit#213` 同一个 PR 里，备份脚本按 Caddy 的
issuer 目录名过滤掉 `staging`，只有生产 CA 签出的证书才会被写入。用两种真
实目录布局（只有 staging / staging+生产并存）验证过滤逻辑。

### 第 5 层：证书明明已经在 Vault 里，取回判据却问错了字段

**现象**：`kv/data/CICD/domains/onwalk.net` 里已经有一张完全合规的证书——
Let's Encrypt 生产签发、SAN 覆盖 `*.onwalk.net`、剩余 88 天有效期、私钥配
对——恢复脚本却每次都打印：

```
Backup entry exists but carries no caddy_data_tar_b64 — treating as no backup.
```

然后放弃恢复，让 Caddy 重新走 ACME。

**根因**：恢复逻辑最初判断“有没有备份”看的是 `caddy_data_tar_b64`（Caddy
内部目录的 tar 打包），而不是通用的 PEM 字段
（`tls_fullchain_pem_b64` / `tls_key_pem_b64`）。某次运维手工整理记录时，
`caddy_data_tar_b64` 字段被清空/删除（这个字段本身设计上就有问题，见下
方“决策”），PEM 字段却是完整的——手里握着一张能用的证书，却因为它不是以
某种特定打包形式存在而被拒绝使用。

**决策**：不是把 `caddy_data_tar_b64` 补回去，而是**彻底废弃这条路**。它
把 Caddy 的私有内部目录布局（`certificates/<issuer>/<name>/` 三件套 +
certmagic 的 `.json` 元数据）冻进了跨环境共享的 Vault 记录格式；换一个
Caddy 版本或 issuer 目录命名，恢复出来的东西就可能对不上，表现是“恢复成功
但 Caddy 还是去签了”——这是一种比“直接失败”更难排查的失败模式，本质上和
第 4 层是同一类风险（“看起来生效，实际没生效”）。

**修复**：`platform-ops-toolkit#214`——恢复判据换成
`tls_fullchain_pem_b64` + `tls_key_pem_b64`；读写两侧彻底移除
`caddy_data_tar_b64`；记录格式收敛为纯 PEM。

## 如何避免：可复用的判断原则

以下每一条都不是“证书特定”的，而是这类“先决条件 → 执行 → 验收 → 反哺先决
条件”循环里通用的检查清单。写代码或做设计评审时，看到类似结构就该过一遍。

### 1. 画出真实的依赖方向，不要相信“大概是这个顺序”

第 1 层和第 3 层是完全相同的错误，出现了两次。原因是没有人真的把
`needs:` 图画出来看过——`initialize_web_saas_databases` 依赖
`deploy_web_saas`、`deploy_web_saas` 内部又要求 accounts 健康、accounts 健
康又依赖建库完成，这是一个环，肉眼读 YAML 很容易漏掉，但画成图一眼就能看
出来。

> **落地动作**：给多 job 的 workflow 加一个 CI 检查，从 `needs:` 提取依赖
> 图并检测环（DAG 校验）。本仓库已经为“0 主机命中仍 exit 0”这类问题写了
> `setup-deployment-runner` 的 Ansible target assertion 守卫（见
> [`2026-07-25-delivery-chain-workplan.md`](../../tasks/2026-07-25-delivery-chain-workplan.md)
> 陷阱 #12），依赖环检测应该是同一优先级的守卫。

### 2. “验收”和“持久化验收结果”必须解耦成两个独立信号

第 3 层的教训：不要用“服务是否健康”去门控“证书要不要存”。这是两个问题：

- 证书本身是否合规、可复用？（第 4/5 层要回答的问题）
- 服务这次部署是否起来了？（observe 要回答的问题）

一旦用后者门控前者的**持久化动作**，任何一次部署失败都会连带阻止“下次部
署变得更容易成功”的手段——形成雪崩：越失败，越没有机会变好。

> **落地动作**：区分“阻塞后续流量的验收”（可以严格）和“为下次运行积累状
> 态的动作”（应当尽量宽松、用 `!cancelled()` 或等价条件，失败时降级为
> `::warning::` 而不是让整个 job 变红）。

### 3. 判断“数据是否可用”，永远直接检查数据本身，不要检查“数据是否以预期格式打包”

第 5 层的教训：判据写的是 `caddy_data_tar_b64` 是否非空，而不是“有没有一
张可用的证书”。这两者在设计时被当成等价物，但字段名和语义会漂移——运维清
理记录、格式重构、版本升级都可能让“打包形式”与“数据本身是否存在”脱钩。

> **落地动作**：`X 是否可用` 的判据应该直接对 X 做校验（能否解析、是否过
> 期、指纹是否匹配），而不是检查某个附属的打包字段是否非空。如果一定要有
> 打包字段（比如为了效率），也要在打包字段缺失时**退而检查原始数据**，而
> 不是直接判定“不可用”。

### 4. 共享状态的“允许复用”判据必须包含“信任来源”这一维度，不能只看“存不存在/过没过期”

第 4 层的教训：证书是否可用，除了“存不存在”“有没有过期”，还有第三个维
度——“是谁签发的”。ACME 环境（生产/staging）、自签证书、第三方 CA 混在同
一个存储位置时，“非空 + 未过期”不足以证明“可安全复用”。

> **落地动作**：任何写入共享存储（尤其是跨环境共享）的自动化步骤，在写入
> 前都要显式校验“来源是否可信”，而不能假设“能生成出来的东西就是好的”。
> 本案例里对应的是 `docs/tasks/2026-07-31-upload-vault-tls-cert.sh` 的六项
> 强制校验：可解析 / SAN 覆盖泛域名 / 私钥配对 / **非 staging 或自签** /
> 剩余有效期 ≥14 天 / 链完整。

### 5. 私有实现细节不能进跨系统/跨版本共享的持久化格式

第 5 层的决策：`caddy_data_tar_b64` 的根本问题不是“字段被清空”，是**设计
时就不该存在**——它把 Caddy 某个版本的内部目录布局当成了 Vault 记录格式的
一部分。跨系统共享的持久化状态应该只用通用格式（这里是标准 PEM），由消费
方（Caddy、stunnel、未来任何需要这张证书的服务）各自用标准方式解析，而不
是把某一个消费方的私有实现细节固化进共享契约。

> **落地动作**：设计跨服务/跨版本共享的存储契约时，问一句“如果消费方明天
> 换了实现（升级版本、换了库），这份记录还能被正确解读吗？” 如果答案依
> 赖于消费方当前版本的内部细节，就不该进共享契约。

### 6. 每一层修复都要用真实环境验证——但真实验证的代价（限流额度）要计入排查预算

本案例的五个根因是**逐层暴露**的：修完第 1 层才能看到第 2 层，修完第 2
层的检查逻辑生效后第 3 层的死锁才会被真实触发，而验证每一层是否修好都需
要一次 destroy + rebuild，每次都消耗当天仅有的几次证书签发额度。

> **落地动作**：涉及外部限流资源（ACME、第三方 API 配额）的调试，优先在
> **不消耗限流的层面**验证——本案例后期改用直接读取 Vault 记录 + 本地
> `openssl` 校验（见下方“如何独立验证”），而不是每次都跑一整套 destroy +
> rebuild 去间接观察限流是否被触发。

## 如何独立验证（不依赖一次完整部署）

排查这类问题时，优先用下面这些**不消耗 ACME 限流额度**的手段，而不是直接
跑 destroy + rebuild：

```bash
# 1. 直接读 Vault 记录，看字段是否齐全（不需要主机、不消耗限流）
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/kv/data/CICD/domains/<domain>" | jq '.data.data | keys'

# 2. 把 PEM 字段解码后用 openssl 独立校验（同 2026-07-30-verify-vault-tls-cert.sh
#    与本次新增的 2026-07-31-upload-vault-tls-cert.sh 的校验逻辑）
openssl x509 -in cert.pem -noout -subject -issuer -dates
openssl x509 -in cert.pem -noout -ext subjectAltName

# 3. 私钥与证书是否配对
diff <(openssl x509 -in cert.pem -noout -pubkey | openssl md5) \
     <(openssl pkey  -in key.pem  -pubout        | openssl md5)

# 4. 在真实主机上直接看 Caddy 日志，判断它当前到底在跟哪个 ACME 目录对话
#    （acme-v02 = 生产, acme-staging-v02 = staging）
ssh root@<host> 'docker logs --tail=100 web-saas-caddy 2>&1 | grep -iE "acme|issuer|429"'

# 5. 用 --list-hosts 验证 Ansible playbook 的 hosts 模式是否真的命中目标
#    （见第 1 层同源问题：hosts 模式写错会静默匹配 0 台主机）
ansible-playbook -i inventory.ini playbook.yml --limit <host> --list-hosts
```

## 相关 PR / 提交索引

| 层 | 修复 | PR |
|---|---|---|
| 第 1 层：建库死锁 | 建库 job 挪到健康检查之前 | [platform-ops-toolkit#164](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/164) / [#165](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/165) |
| 第 2 层：健康检查形同虚设 | 新增 `observe_web_saas`，不依赖 `confirm_dns_switch` | [platform-ops-toolkit#170](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/170) |
| 基础设施 | Caddy + Cloudflare DNS 镜像 | [artifacts#183](https://github.com/ai-workspace-infra/artifacts/pull/183) |
| 基础设施 | ansible-lint 迁离失效 registry | [artifacts#184](https://github.com/ai-workspace-infra/artifacts/pull/184) |
| 接线 | 泛域名 Caddyfile + DNS-01 + `caddy.env` | [playbooks#202](https://github.com/ai-workspace-infra/playbooks/pull/202) / [#203](https://github.com/ai-workspace-infra/playbooks/pull/203) |
| 接线 | `CADDY_IMAGE` 换镜像 + 补 `env_file` | [gitops#124](https://github.com/ai-workspace-infra/gitops/pull/124) |
| 接线 | 下发 `CLOUDFLARE_DNS_API_TOKEN` + 证书持久化脚手架 | [platform-ops-toolkit#171](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/171) / [#172](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/172) |
| Vault 策略 | 域名证书共享路径授权 | `docs/tasks/vault_auth_split.sh`（随 #172 一并提交） |
| 第 3/4 层：备份死锁 + staging 误存 | 备份改 `!cancelled()`；过滤掉 staging 证书 | [platform-ops-toolkit#213](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/213) |
| 第 5 层：取回判据用错字段 | 恢复判据换 PEM 字段；废弃 `caddy_data_tar_b64` | [platform-ops-toolkit#214](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/214) |
| 运维工具 | 手工上传/续期证书 + 六项强制校验 | `docs/tasks/2026-07-31-upload-vault-tls-cert.sh`（随 #214 提交） |

## 交叉引用

- [`2026-07-29-domain-wildcard-tls-reuse.md`](../../tasks/2026-07-29-domain-wildcard-tls-reuse.md)
  ——泛域名证书跨环境共享的决策与 Vault 契约字段定义
- [`2026-07-30-verify-vault-tls-cert.sh`](../../tasks/2026-07-30-verify-vault-tls-cert.sh)
  ——只读校验脚本（本案例新增的上传脚本复用了同一套校验逻辑并加了写入前
  的强制门槛）
- [`2026-07-25-delivery-chain-workplan.md`](../../tasks/2026-07-25-delivery-chain-workplan.md)
  ——本仓库更早期发现的一组同类陷阱（#11 `exportToken`、#12 `--list-hosts`
  假绿、#16 空口令不崩溃），第 1 层与第 5 层的教训与陷阱 #12、#16 是同一
  类问题的不同实例
