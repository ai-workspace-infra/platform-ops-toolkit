# UAT `web-saas + agent-proxy` 鲁棒性部署验收用例

## 目标

验证每次使用不可变 tag 从零创建 UAT 副本后，能够稳定完成：

`Vultr IaC 资源申请 -> 主机初始化 -> Web SaaS 与 Agent Proxy 部署 -> Agent 注册/心跳 -> Xray/Caddy 入口 -> 业务探针 -> DNS 发布`。

本轮固定参数：

| 参数 | 值 |
|---|---|
| 环境 | `uat` |
| 云厂商 | `vultr-vps` |
| 部署 tag | `daily-build-2026.07.31` |
| 域名后缀 | `onwalk.net` |
| 业务域 | `web-saas + agent-proxy` |
| 规格 | 单域 `2C4G`；agent-proxy 按矩阵使用 `1C2G` |
| 初始化 | `run_full_stack=true` |
| DNS | `confirm_dns_switch=true` |

## 用例清单

### TC-00：Terraform state 路由与复用

**目标**：确认 apply/destroy 使用规范化 state，避免 key 或 workspace 漂移导致重复创建资源。

**断言**：本次 UAT 业务域的最终值必须是：

```text
state_key = uat/vultr-vps/platform-ops-toolkit/web-saas-agent-proxy.tfstate
workspace = uat-vultr-vps-platform-ops-toolkit-web-saas-agent-proxy
```

对相同参数重新执行时，Terraform 必须先 `init` 并选择上述 workspace；已存在资源时
plan 不得重新创建，destroy 必须针对同一个 state 生成销毁计划。

**演进约束**：旧 state key 不在常规流水线中自动兼容。未来发生 state 层级迁移时，必须先
冻结旧流水线、备份 state、核对实例 ID，再通过独立迁移任务完成新 key 导入，并用
`terraform plan` 验证 `0 to add / 0 to destroy` 后恢复部署。

### TC-01：路由参数与资源规格

检查 workflow 的 `Resolve Profile` 输出：

```text
deployment_env=uat
target_domains=web-saas + agent-proxy
cloud_provider=vultr-vps
target_domain_base=onwalk.net
deploy_tag=daily-build-2026.07.31
terraform_action=apply
run_infrastructure=true
run_application_deploy=true
confirm_dns_switch=true
```

通过标准：同时生成 `web-saas.yaml` 与 `agent-proxy.yaml` 资源输入；web-saas 为 2C4G，agent-proxy 为 1C2G；不得出现 `prod` 或 `tky-proxy.svc.plus` 作为 UAT agent endpoint。

### TC-02：IaC 与主机初始化

`web-saas + agent-proxy` 的新副本必须满足以下交付顺序：

```text
web-saas/agent-proxy IaC
        ↓
web-saas 主机 bootstrap + Accounts/Console 健康
        ↓
agent-proxy A 记录前置发布 + 公网 DNS 传播确认
        ↓
agent-proxy native bootstrap
        ↓
 Caddy ACME 证书 + agent 首次注册/同步并生成 Xray 配置
        ↓
web-saas/Accounts/DNS 最终发布与公网观测
```

agent-proxy 不能在 Accounts 尚未可达时等待，也不能在 Caddy 证书尚未生成时校验
`/usr/local/etc/xray/config.json`；部署 agent 时流水线会从本次 CMDB 读取
web-saas IP，临时把 `accounts-<env>.<target_domain>` 解析到该 IP，保留 HTTPS
主机名/SNI。同时只把 `agent-proxy.<target_domain>` 的 A 记录前置指向本次
agent-proxy IP，让 Caddy 能为 Xray 所引用的域名完成公网 ACME；Xray 校验前必须
等待 `/var/lib/caddy/.local/share/caddy/certificates/.../<agent>.crt` 出现。DNS
最终发布步骤会再次幂等对账全部记录，并删除 agent 主机上的 `/etc/hosts` 临时覆盖，
避免下次主机替换继续使用旧 IP。

在 workflow 中确认以下 job 全部成功：

- Terraform Apply
- Bootstrap Node（web-saas、agent-proxy）
- Initialize Agent Proxy Credentials
- Initialize Web SaaS PostgreSQL Databases

主机侧：

```bash
hostname
systemctl is-active caddy agent-svc-plus xray xray-tcp
systemctl is-enabled caddy agent-svc-plus xray xray-tcp
```

通过标准：所有命令返回成功；systemd unit 同时为 `active` 和 `enabled`。

### TC-03：固定版本与可重复更新

在 agent-proxy 主机执行：

```bash
/usr/local/bin/xray version
sha256sum /usr/local/bin/xray
XRAY_LOCATION_ASSET=/usr/local/share/xray \
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
XRAY_LOCATION_ASSET=/usr/local/share/xray \
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/tcp-config.json
```

通过标准：Xray 版本为部署声明的固定版本；两个配置测试返回 0；`geoip.dat` 和 `geosite.dat` 存在；重复执行部署不会产生随机 UUID、无意义重启或版本漂移。

### TC-04：Agent 注册、心跳与配置同步

在 Accounts 主机日志中检查：

```bash
docker logs --since 10m <accounts-container> 2>&1 \
  | grep '/api/agent-server/v1/status'
```

在 agent-proxy 主机检查：

```bash
journalctl -u agent-svc-plus --since '10 minutes ago' --no-pager \
  | grep -E 'xray config synchronized|failed to report'
```

通过标准：Accounts 持续收到 `POST /api/agent-server/v1/status` 并返回 `204`；agent ID 为当前 UAT 主机域名；Xray 同步报告客户端数量大于 0；不得出现 `401/403`、DNS 解析失败或连续心跳失败。

### TC-05：Caddy 与公网入口

```bash
caddy validate --config /etc/caddy/Caddyfile
ss -lntp | grep -E ':(443|1443)'
curl -kfsS https://agent-proxy.onwalk.net/
curl -ksS -o /dev/null -w '%{http_code}\n' https://agent-proxy.onwalk.net/split/test
```

通过标准：Caddy 配置有效；443 由 Caddy 监听、1443 由 Xray 监听；根路径返回 `Agent Service Plus Node`；`/split/test` 到达 XHTTP 入口，非法测试请求返回 400 属于预期，不应是连接失败或 404。

### TC-06：二维码配置来源

从控制台获取当前用户的 VLESS 二维码或复制链接，解析其 URI：

```text
DOMAIN=agent-proxy.onwalk.net
PORT=443                  # XHTTP
TYPE=xhttp
PATH=/split
SECURITY=tls
```

通过标准：二维码不得包含 `tky-proxy.svc.plus`、`accounts.svc.plus`、旧 IP 或生产域名；二维码中的域名可解析到本次 UAT agent-proxy 主机；XHTTP path 与 Xray 配置一致。

### TC-07：Web SaaS 业务与观测探针

确认 workflow 的以下 job 成功：

- Deploy Web SaaS Services
- Observe Web SaaS
- Switch DNS Traffic & Observe

外部检查：

```bash
curl -fsS https://console-uat.onwalk.net/
curl -fsS https://accounts-uat.onwalk.net/
dig +short console-uat.onwalk.net A
dig +short accounts-uat.onwalk.net A
dig +short agent-proxy.onwalk.net A
```

通过标准：三个域名都解析到本次 UAT 资源；Console 与 Accounts 返回 2xx；观察步骤不能只检查文件存在，必须验证实际 HTTPS handshake/HTTP 响应。

### TC-08：重启持久性

在所有 agent-proxy 服务完成后执行一次受控重启：

```bash
systemctl reboot
```

主机恢复后重复 TC-02、TC-03、TC-04、TC-05，等待最多 10 分钟。

通过标准：Caddy、Xray、agent-svc-plus 均自动恢复；Agent 在 2 个心跳周期内重新注册；二维码域名和 UUID 不变化；Xray 配置无需人工复制或手工启动。

### TC-09：幂等更新

使用同一个 `daily-build-2026.07.31` 再执行一次应用部署，不销毁资源、不切换 DNS。

通过标准：部署成功；Xray 版本、UUID、Caddy 域名和证书不变；无生产域名混入；服务最终保持 active/enabled；观察探针仍成功。

## 失败分类

| 现象 | 优先检查 |
|---|---|
| `203/EXEC` | `/usr/local/bin/xray` 是否由 playbook 安装，版本/架构是否正确 |
| 配置测试缺 `geoip.dat` | `/usr/local/share/xray` 与 `XRAY_LOCATION_ASSET` |
| 443 未监听 | Caddy import 扩展名、域名模板、ACME 证书和 Caddy reload |
| Xray 配置测试找不到 agent-proxy 证书 | agent-proxy A 记录前置发布、`@1.1.1.1` 传播结果、Caddy ACME 日志和证书路径；不得跳过等待直接启动 Xray |
| Agent 无心跳或 Xray 配置未生成 | `AGENT_CONTROLLER_URL`、本次 CMDB controller IP 临时解析、UAT Accounts DNS、token、Accounts 204 日志 |
| 二维码混入生产域 | `AGENT_PROXY_DOMAIN`、Caddy domains、Accounts 返回的 URI scheme |
| 重启后服务消失 | unit 是否 `enabled`，是否依赖手工启动或临时文件 |

## 交付判定

只有 TC-01 至 TC-09 全部通过，且 workflow 的部署、业务观察、DNS 观察 job 均为 success，才判定该 tag 可作为“每次可重复拉起在线业务系统”的合格发布版本。
