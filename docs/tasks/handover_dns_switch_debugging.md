# Handover: CD Pipeline & DNS Switch Debugging

目标:`platform-ops.yaml` 端到端跑通 —— IAC → Doco-CD 用
`https://github.com/ai-workspace-infra/gitops.git` 在 UAT 主机启动 web-saas 套件
→ DNS 生效。

UAT 主机:`console-uat.onwalk.net` / `167.179.64.91`(Vultr nrt)。

## 已闭环(合入 main)

- #90 skip 沿 needs 链传递缺 always()
- #93 脚本 exec 位
- #97 playbooks role 绑错 repository claim(跨仓 uses: 时 repository 是调用方)
- #98 / playbooks#179 Doco-CD git token 改可选(公开仓库不需要)
- playbooks#180 Doco-CD 声明 Docker 依赖
- playbooks#181 domain-cd 跨仓 checkout 显式指定 repository
- playbooks#183/#184 web_saas_host_config 角色 + Doco-CD 轮询 gitops(60s) + domain-cd 真正发布 tag
- #105 数据库口令从 kv/data/<env>/databases 读(不再是 legacy WEB_SAAS)

## 当前调试焦点:instance_plan 与 resize

### 现象一:2C4G 触发降配保护(预期行为,非缺陷)

`instance_plan=2C4G` 但主机实为 `vc2-4c-8gb`。Terraform 计划 in-place 改 plan,
被 provision 的守卫拦下:

> Vultr does not support in-place VPS downgrades. Re-run ... action=resize

降配必须走 `action=resize` 的"快照-验证-接管 state-部署"替换流程,不是 deploy。

### 现象二:resize preflight 对 instance_id 报 404(已修 #106)

`action=resize` 后 preflight `curl GET /v2/instances/{id}` 返回 404,
以 `curl: (22)` + exit 22 死掉。

**实证判据**(直接打 Vultr API):无效/空 token 一律 **401**,只有 token 有效
但账户无此 ID 才 **404**。所以 404 = ID 陈旧,不是凭据问题。

**根因**:`167.179.64.91` 的 SSH host key 与 known_hosts 不符 → 主机被重建过、
换了新 instance ID;而传入 preflight 的 ID 来自 CMDB(由 Terraform state 生成),
仍是旧 ID `bd872f91...`。

> ⚠️ 一处尚未解释清的矛盾,留给下一手核实:provision 在 03:22
> (run 30063710395)成功 `Refreshing state... [id=bd872f91...]` 并读出
> live plan=vc2-4c-8gb —— 说明当时同一个 uat key 能读到 bd872f91;而 06:19
> resize preflight 用同路径 key 却 404。两者之间(用户填 Vault、合 #105)
> 若实例又被重建或 uat 的 VULTR_API_KEY 被换过,可解释此矛盾。无论哪种,
> #106 的按 label/IP 自愈都能处理。

**#106 的修复**:preflight 显式读 HTTP 码,401/403(凭据)与 404(ID 陈旧)
分开报;404 且 token 有效时从账户实例列表按 label(target_domain)或 IP 现查
真实 ID —— 不再硬编码/盲信一个可能陈旧的 ID。

### 打通决策:先用 action=deploy + 4C8G

用户要求"先打通"。resize 的 DNS 切换只在 `direction==downgrade` 时触发,
而降配正卡在陈旧 ID 上。所以打通走正常 `action=deploy` 路径:

- `instance_plan=4C8G` 与现有实例一致 → Terraform no-op,绕开 resize;
- 正常路径有独立的 `switch_dns` job(挂 environment: production,需人工审批);
- `confirm_dns_switch=true`。

### 现象三:deploy_base 在 Load Vault secrets 失败(已修 #107,待合)

run 30072783294:**provision 成功(Terraform no-op,4C8G 与实例一致,resize
彻底绕开)**,但 `Bootstrap Node` 在 `Load Vault secrets` 挂:

> Unable to retrieve result for data.data."postgres_root_password". No match data was found.

**根因**:init 脚本探测 `kv/data/uat/databases` 得 `200` → "已存在,跳过",
但那个 secret **缺 `postgres_root_password` 键**。存在 ≠ 完整。02:26 那次成功
是在 #105(把读取路径从 `WEB_SAAS` 改到 `uat/databases`,05:54 合)**之前**,
当时 postgres 口令读的是旧路径 `WEB_SAAS`。

**#107**:init 幂等判据改为"必需键是否齐全",缺键 merge-patch 补齐(已有键
不动,不轮换在用口令);干净 404 写完整键集。

### 主机状态:全新空白,无口令对齐问题

`167.179.64.91` 已被重建(host key 变了,已更新本地 known_hosts):**docker
未装、0 容器、0 卷、/etc/xcontrol 与 /opt/doco-cd 均不存在,uptime ~1h**。
所以不存在"旧口令已初始化 postgres"的对齐问题 —— 新口令首次初始化即可。
用户已确认 UAT 可重建。

### 现象四:补键用 HTTP PATCH 得 403(已修 #109,待合)

run 30073339591:init 正确诊断"secret 存在但缺 postgres_root_password",
但用 HTTP `PATCH` 补键返回 **403** —— KV v2 patch 需要 policy 里专门的
`patch` capability,各环境 policy 只给了 create/read/update/delete/list。

**#109**:改为读-合并-写(已读的 .data.data 与新生成缺失键合并后整体 POST,
只用已授权的 update;已有键值原样保留)。

### instance_plan 覆盖:机制本就是通的(不是缺陷)

用户强调"新建主机选 2C4G 需能覆盖默认值"。链路完整且已生效:
`instance_plan=2C4G` → Map Instance Plan(vc2-2c-4gb)→ INSTANCE_PLAN_API →
generate.py render → 资源 YAML `plan: {{ env.get('INSTANCE_PLAN_API', ...) }}`。
run 30063710395 的 TF 计划 `vc2-4c-8gb -> vc2-2c-4gb` 即证据。2C4G 没"直接成功"
是因为对已存在的 4C8G 主机做 in-place 降配被守卫拦下,与覆盖无关。

**决策(用户确认)**:先用 4C8G 打通全链路,再销毁重建为 2C4G 验证降配路径。

**后续项(未做,勿轻改)**:9 个资源 YAML 的 `env.get('INSTANCE_PLAN_API',
'vc2-4c-8gb')` 有 fallback 默认值,违反 IaC 规范"渲染变量不设默认值"。但这些
文件也被多云 matrix 流水线消费,改成必填 `env['INSTANCE_PLAN_API']` 前要先确认
那些渲染路径都设了此变量,否则会拖垮它们。含 prod 文件,需谨慎。

### 待办(合 #109 后)

1. 合 **#107** → 重新触发同一条 deploy(4C8G / action=deploy /
   confirm_dns_switch=true / vault_env_path=uat)。
2. 预期链路:provision(no-op)→ deploy_base(docker 安装 +
   web_saas_host_config + Doco-CD 轮询 gitops 60s)→ deploy_web_saas(发布
   tag 到 gitops)→ Doco-CD 拉起套件 → switch_dns(人工审批)。
3. 打通后再按用户后续要求:(a)真降配到 2C4G 走 action=resize(依赖 #106);
   (b)调整 ENV 定义 / 环境变量切换。

### 触发命令(打通路径)

```bash
gh workflow run platform-ops.yaml --repo ai-workspace-infra/platform-ops-toolkit --ref main \
  -f runner_type=ubuntu-latest -f source_host=install.svc.plus \
  -f source_domain_base=svc.plus -f target_domain_base=onwalk.net \
  -f run_infrastructure=true -f run_application_deploy=true \
  -f target_domains=web-saas -f cloud_provider=vultr-vps \
  -f instance_plan=4C8G -f action=deploy \
  -f confirm_dns_switch=true -f vault_env_path=uat
```

## Vault 路径备忘(用户已填)

- 数据库口令:`kv/data/<env>/databases`(postgres_root_password /
  account_pg_password / billing_pg_password)
- web-saas 业务密钥 + stunnel 证书:`kv/data/WEB_SAAS`
- Cloudflare(DNS 切换):`kv/data/CICD` 根路径,键 `CLOUDFLARE_API_TOKEN`
  (resize-instance.yaml 已指向此路径)
- 基础凭据(VULTR_API_KEY / TF_STATE_* / SSH):`kv/data/CICD/<env>`
- GITOPS_TOKEN(CD 写 gitops):`kv/data/CICD/<env>`,公开仓库故设计为可选

## 安全:仍待用户手动处理(见 2026-07-24-secret-leak-ledger.md)

MFA TOTP × 4 账号 / SMTP 密码 / OAuth token 轮换;gitops 仓 WireGuard 私钥净化。
