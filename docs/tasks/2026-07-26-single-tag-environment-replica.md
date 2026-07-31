# 单个 tag 点拉起 SIT / UAT / PROD 环境副本

## 目标

用一个明确的 Git tag / ref 作为副本基准，拉起任意 `sit`、`uat`、`prod` 环境副本，并包含基础设施、节点 bootstrap、业务域服务部署和可选 DNS 发布。

本次验证基准 tag：

```text
uat-platform-rebuild-2026.07.26
```

这不是产品 release tag，而是平台化工程复建 UAT 环境的快照节点。它用于让 `workflow_dispatch` 在同一个时间点拉取 `platform-ops-toolkit`、`iac_modules`、`playbooks` 和 `xworkspace-console`，避免不同仓库引用漂移。

## Workflow 入口

GitHub Actions：

```text
Deploy Environment & Provision Infrastructure
```

触发方式：

```text
workflow_dispatch
```

## 核心输入约定

| 输入 | 推荐值 | 说明 |
|---|---|---|
| `runner_type` | `ubuntu-latest` | 默认云端 runner；需要内网访问能力时再切 `self-hosted` |
| `deploy_ref` | `uat-platform-rebuild-2026.07.26` | 单一副本基准，默认同时作为 toolkit / infra / console ref |
| `toolkit_ref` | 空 | 留空时回退到 `deploy_ref` |
| `infra_ref` | 空 | 留空时 `iac_modules` 与 `playbooks` 回退到 `deploy_ref` |
| `console_ref` | 空 | 留空时 `xworkspace-console` 回退到 `deploy_ref` |
| `deploy_tag` | `daily-build-YYYY.MM.DD-rN` | 业务服务的不可变镜像版本；启用应用部署时必须显式填写，绝不从 `deploy_ref` 推导 |
| `vault_env_path` | `sit` / `uat` / `prod` | 决定环境、Vault 路径、Terraform workspace 与 state key |
| `target_domains` | `web-saas` 或 `all` | 当前 UAT 复建优先验证 `web-saas` |
| `run_full_stack` | `true` | 一键打开 IaC、服务部署和 DNS 发布开关 |
| `run_infrastructure` | `true` | 只在不使用 `run_full_stack` 时手动打开 |
| `run_application_deploy` | `true` | 包含业务服务部署；必须和 `run_infrastructure=true` 一起使用 |
| `cloud_provider` | `vultr-vps` | 多云选项为预留，目前这条环境副本链路实际能跑的是 `vultr-vps` |
| `action` | `deploy` | 创建或收敛环境副本 |
| `source_domain_base` | `svc.plus` | 源环境域名后缀 |
| `target_domain_base` | `onwalk.net` | 目标环境域名后缀 |
| `confirm_dns_switch` | 按需 | 只有需要发布 DNS 时才打开 |

## 环境副本矩阵

### SIT 副本

```text
vault_env_path=sit
deploy_ref=uat-platform-rebuild-2026.07.26
deploy_tag=sha-<40 位完整 commit SHA>
run_full_stack=true
target_domains=web-saas
cloud_provider=vultr-vps
```

SIT 会使用 `sit` Vault role 和 `sit` Terraform state。默认资源文件为 `sit/all-in-one`。

### UAT 副本

```text
vault_env_path=uat
deploy_ref=uat-platform-rebuild-2026.07.26
deploy_tag=daily-build-2026.07.26-r1
run_full_stack=true
target_domains=web-saas
cloud_provider=vultr-vps
```

UAT 会使用 `uat` Vault role 和 `uat/web-saas` Terraform state。手动副本模式下，`deploy_tag` 必须是调用方提供的不可变镜像版本；`deploy_ref` 仅控制源码或基础设施 checkout，不能作为镜像版本的回退值。

### PROD 副本

```text
vault_env_path=prod
deploy_ref=uat-platform-rebuild-2026.07.26
deploy_tag=v1.2.3
run_full_stack=true
target_domains=web-saas
cloud_provider=vultr-vps
```

PROD 副本会使用 `prod` Vault role 和 `prod/web-saas` Terraform state。`workflow_dispatch` 的 prod 副本是显式恢复/复建动作，不等同于 `v*` 产品 release 发布。

## 执行链路

1. Checkout `platform-ops-toolkit`：使用 `toolkit_ref || deploy_ref`。
2. Route profile：根据 `vault_env_path` 计算环境、资源文件、workspace、state key。
3. Checkout `iac_modules`：使用 `infra_ref || deploy_ref`。
4. Checkout `playbooks`：使用 `infra_ref || deploy_ref`。
5. Terraform render/init/apply：生成 CMDB 与 inventory。
6. Bootstrap Node：按 CMDB 初始化目标主机。
7. Domain CD：按 `target_domains` 委派到 `playbooks` 域级 workflow。
8. DNS 发布：仅在 `confirm_dns_switch=true` 或 `run_full_stack=true` 的语义下进入最后发布阶段。

## 验收标准

- `Resolve Profile, Provision Environment & Init Secrets` 成功。
- `deploy_base` 至少有一个目标主机完成 bootstrap。
- 目标业务域的 CD job 未被错误 skip。
- `web-saas` 场景下，`console`、`accounts`、`billing`、`postgresql`、`stunnel-client`、`stunnel-server`、`caddy` 全部完成部署或由 Doco-CD 收敛。
- `confirm_dns_switch=true` 时，DNS job 明确执行并成功。
- 服务侧不连接 `svc.plus` 的旧环境数据库或 stunnel endpoint。

## 注意事项

- `cloud_provider` 仍展示多云选项，因为这是平台产品形态预留；当前环境副本链路只对 `vultr-vps` 接线完成。
- `deploy_ref` 是副本基准，不代表产品 release。
- 应用部署必须显式填写 `deploy_tag`；`main`、`latest` 和空值均会被拒绝。
- 如果需要对某个仓库临时验证不同 ref，可以只覆盖 `toolkit_ref`、`infra_ref` 或 `console_ref`，其余继续跟随 `deploy_ref`。
- `run_application_deploy=true` 必须和 `run_infrastructure=true` 一起使用，因为部署 inventory 由 provision 阶段生成。
