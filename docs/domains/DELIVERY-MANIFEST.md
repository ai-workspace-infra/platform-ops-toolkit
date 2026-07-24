# 领域交付清单 (Domain Delivery Manifest)

四个业务域的交付边界。这份清单是**领域与交付入口的映射**，不是脚本堆放处 ——
`platform-ops.yaml` 只按域委派，不再为单个服务追加 step。

> 这份清单属于本仓库，不属于 `engineering-standards` skill。skill 里只保留**与业务无关的**
> 委派模式与约束；具体有哪些域、每个域含哪些服务，是本项目的事实，会随业务演进而变，
> 放进通用规范会让规范失去可复用性。

## 边界

| 环节 | 归属 | 说明 |
|---|---|---|
| 服务代码构建 (CI Build) | **各服务开发仓库** | 产出带版本标识的制品/镜像 |
| 领域交付 (CD) | **`playbooks` 仓的域 CD workflow** | 消费已构建的制品，按 `deploy_tag` 部署 |
| 基础设施与编排 | **本仓 `platform-ops.yaml`** | provision → CMDB → bootstrap → 委派域 CD → migration → DNS |

`platform-ops-toolkit` **不检出业务仓库、不构建服务二进制或镜像**。它只产出并传递：
环境、CMDB artifact、目标主机、部署版本 (`deploy_tag`)、环境专属 Vault OIDC 上下文。

## 四个领域

| 领域 | 负责服务 | CI Build 所属 | CD 入口 | Bootstrap playbook |
|---|---|---|---|---|
| `web-saas` | Console、Accounts、Billing、Caddy | 各服务开发仓库 | `web-saas-domain-cd.yaml` | `setup-Doco-CD.yaml` |
| `ai-workspace` | LiteLLM、OpenClaw、QMD、Agent/Model routing | 各服务开发仓库 | `ai-workspace-domain-cd.yaml` | `setup-ai-workspace-rootless.yml` |
| `agent-proxy` | Caddy、Xray、Exporter、Vector、agent-svc-plus | 对应服务仓库 | `agent-proxy-domain-cd.yaml` | `setup-agent-proxy-domain.yml` |
| `open-platform` | Gitea、Vault、Zitadel、Grafana、VictoriaMetrics 等 | 对应基础服务/制品仓库 | `open-platform-domain-cd.yaml` | `setup-open-platform-domain.yml` |

CD 入口均位于 `ai-workspace-infra/playbooks/.github/workflows/`，四者共用底层
`domain-cd.yaml` runtime。

## 部署版本约定

CD **绝不在部署时决定版本**，版本必须由调用方显式传入 `deploy_tag`：

| 环境 | `deploy_tag` |
|---|---|
| SIT | 用户定义（dispatch 时显式给出） |
| UAT | `latest` |
| PROD | 触发它的 `v*` tag 或 `release/*` |

> 这条约定的意义在于：**PR CI 只证明代码可交付，CD 才负责改变 SIT/UAT/Prod 环境**。
> 没有显式版本就等于"部署此刻的 main"，那是一次无法复现、也无法回滚到确切内容的发布。

这里规定的是 CD **消费**哪个 tag。各服务仓的 CI Build 必须**生产**与之对应的
tag，两者的严丝合缝由 [镜像 Tag 跨仓契约](IMAGE-TAG-CONTRACT.md) 保证 ——
少一个仓库不遵守，同一个 `deploy_tag` 就只能寻址到一部分服务，而部署仍会报成功。

## 新增一个领域时

1. 在 `playbooks` 仓新增 `<domain>-domain-cd.yaml`，委派给共享的 `domain-cd.yaml`
2. 在 `config/resources/<env>/*.yaml` 里给主机打上该域的 group
3. 在 `platform-ops.yaml` 增加一个 `uses:` 委派 job，条件复用既有形态
4. 更新本清单

**不要**在 `platform-ops.yaml` 里为该域的单个服务追加 step —— 那正是这份清单要终结的模式。
