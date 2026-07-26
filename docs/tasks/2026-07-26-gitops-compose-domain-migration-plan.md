# 任务 2 详细规划：`ai-workspace` / `agent-proxy` / `open-platform` 迁移到 compose + Doco-CD

面向交接写的。**先说结论：这不是"照抄 web-saas 模式补三份文件"，是三次独立的架构迁移**，
难度、未知数、阻塞因素完全不同。把这当成机械重复工作分给盲跑的 subagent 会产出
看起来合理、实际编造的 compose 文件——与本会话一直在清除的那类缺陷同源。

## 现状核查（2026-07-26 实测，非推测）

`gitops/compose/` 目前只有 `web-saas`。其余三个域**至今是纯 Ansible 直接装在
主机上，从未 compose 化**：

```
setup-open-platform-domain.yml:
  - import_playbook: setup-vault.yaml
  - import_playbook: deploy_zitadel_docker.yaml
  - import_playbook: deploy_grafana_docker.yaml
  - import_playbook: deploy_VictoriaMetrics_docker.yaml

setup-agent-proxy-domain.yml:
  - import_playbook: deploy_xray_proxy_server.yml
  - import_playbook: deploy_xray_exporter.yml

setup-ai-workspace-rootless.yml:
  - import_playbook: deploy_gateway_openclaw.yml
  - import_playbook: deploy_agent_hermes.yml
```

逐个服务核实了是否已容器化、镜像来自哪、有没有数据库依赖：

| 域 | 服务 | 现状 | 迁移到 compose+Doco-CD 的难度 |
|---|---|---|---|
| open-platform | Vault | Ansible 原生装（`setup-vault.yaml`），非容器 | **高**：Vault 是有状态存储+unseal 流程的服务，不应该交给"拉新镜像就重启"的 Doco-CD 模型 |
| open-platform | Zitadel | 已有可用 compose 模板（`roles/docker/zitadel/templates/docker-compose.yaml`），镜像 `ghcr.io/zitadel/zitadel:latest`，**已声明依赖 Postgres**（`ZITADEL_DATABASE_POSTGRES_*`） | **低**：这是本域里唯一真正匹配"复制 web-saas 的 postgres+stunnel 模式"的服务 |
| open-platform | Grafana | 已有 compose 模板，镜像 `grafana/grafana:10.4.6` | **低**：拆 config/dashboard provisioning 到 Vault/主机侧 |
| open-platform | VictoriaMetrics | **role 是占位符**（`README.md` 原话："Placeholder role... Templates include docker-compose.yaml with bootstrap nginx and certbot services"）——compose 模板里的镜像其实是 `nginx:mainline-alpine` 和 `certbot/certbot`，**不是 VictoriaMetrics 本体** | **未知**：需要先找到真正的 VM 部署方式，这个角色目前不能作为规格来源 |
| agent-proxy | Xray 代理 | `deploy_xray_proxy_server.yml` | 需细读，未逐行核实是否容器化 |
| agent-proxy | agent-svc-plus | **从 Go 源码编译**（`agent_svc_plus_repo_url` / `agent_svc_plus_go_version`），不是拉镜像 | **高**：Doco-CD 的模型是"拉镜像、起容器"，源码编译的服务不天然适配。要迁移，得先给它写 Dockerfile、接 CI 构建推镜像——这是 web-saas 三个服务当初已经走过的路，不是一次配置搬运 |
| agent-proxy | Xray Exporter | `deploy_xray_exporter.yml` | 需细读 |
| ai-workspace | OpenClaw gateway | `roles/vhosts/gateway_openclaw/`，任务文件是 `macos.yml`/`windows.yml`/`main.yml`——**按操作系统原生安装，非容器** | **高**：同 agent-svc-plus，需要先决定要不要容器化这个服务本身 |
| ai-workspace | Agent Hermes | `roles/vhosts/acp_server_hermes/`，同样是 `install.yml`/`config.yml` 原生安装 | **高**，同上 |
| ai-workspace | LiteLLM / QMD | manifest 提到，但本次未找到对应的 playbook import——需要先确认这两个服务今天是怎么部署的，还是压根没有 | **未知** |

## 为什么"每个域都有 postgresql/stunnel-client/stunnel-server"这句话只对了一部分

这条要求源于 web-saas 的真实需求：Accounts/Billing 需要一个通过 stunnel 加密隧道
访问的独立 Postgres。**但这是服务的属性，不是域的属性。** 核实下来：

- **open-platform**：Zitadel 需要 Postgres，这条成立，应该给它配一套。Vault 有自己的
  存储后端（不是 Postgres，取决于当前配置——需要先读 `setup-vault.yaml`
  确认存储引擎，参见"待确认"）。Grafana/VictoriaMetrics 通常不需要独立 Postgres。
- **agent-proxy**：manifest 列出的服务（Caddy/Xray/Exporter/Vector/agent-svc-plus）
  里，目前没有一个已知依赖 Postgres。除非 agent-svc-plus 自己连了数据库（需要读
  它的源码仓库确认），这个域可能**不需要**新的 postgres/stunnel 对。
- **ai-workspace**：LiteLLM 常见部署会用 Postgres 做请求日志/预算追踪，但这次没有
  找到本仓库里 LiteLLM 的实际配置来确认。OpenClaw/QMD 未知。

**所以不要预先在三个域都建 postgres/stunnel-client/stunnel-server**——先确认哪个
服务真的需要数据库，再建。凭空建一套连不上任何东西的 stunnel 隧道，本身就是
本会话陷阱清单第 16 条那类"不报错的错误配置"。

## 待确认（这些不是我能从代码推断的事实，需要人工回答）

1. **Vault 是否要迁移进 compose？** 它当前是主机原生装的、承载着全部密钥体系
   （包括这次会话里反复用到的 role/policy）。把它挪进"Doco-CD 拉镜像即重启"的
   模型，意味着每次业务发布都有可能触碰到 Vault 的生命周期——这是个需要显式
   决策的架构问题，不是顺手做的事。**建议本轮先跳过 Vault，只迁移
   Zitadel/Grafana。**
2. **VictoriaMetrics 的真实部署方式是什么？** 现有 role 是占位符，不能作为规格来源。
3. **agent-svc-plus 与 OpenClaw gateway 要不要容器化？** 这决定了 agent-proxy 与
   ai-workspace 这两个域本轮能推进到什么程度——如果不容器化，这两个域这次
   只能先跳过，等对应服务仓库有了 Dockerfile + CI 之后再迁移，就像 web-saas
   当初经历的那样。
4. **LiteLLM / QMD 今天到底部署在哪、怎么部署？** manifest 提到了，但本次没找到
   对应的 Ansible import。

## 建议的分工方式（回答上述问题之后）

按已核实的难度排序，不是按域排序：

1. **Zitadel（open-platform 的子集）**——现成 compose 模板、现成镜像、已声明
   Postgres 依赖，是本轮唯一能直接照抄 web-saas 模式的目标。可以先做这一个，
   验证"迁移到 compose+Doco-CD"这条路径本身是通的，再谈其余。
2. **Grafana（open-platform 的子集）**——现成镜像，无数据库依赖，比 Zitadel 更简单，
   可以并行做。
3. **VictoriaMetrics**——先派一个只读研究任务（不写代码）：找到当前生产环境
   VictoriaMetrics 到底怎么跑的（如果确实在跑），因为现有 role 不能当规格来源。
4. **agent-proxy / ai-workspace 剩余部分**——在"待确认 3"有答案之前不要开始写
   compose，那会是无源之水。

## 与当前会话目标的关系

本文档记录的三个域**不阻塞** `deploy_web_saas` UAT + DNS 这个目标——那个目标
只依赖 web-saas 域，已经在跑（见
[2026-07-25 工作计划](2026-07-25-delivery-chain-workplan.md)
与 [console 构建记录](2026-07-26-console-build-and-prod-leak-audit.md)）。
这里记录的是后续任务，供当前部署跑通之后接续。
