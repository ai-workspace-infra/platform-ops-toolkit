# platform-ops-toolkit

中文向导

`platform-ops-toolkit` 是平台运维的**入口仓库**，不是所有基础设施配置的存放地。
新人只需要先记住这一点：日常真正要改的配置，主要在下面三个核心仓库；本仓库负责把它们组装起来，并通过 GitHub Actions 执行。`artifacts` 是可选的辅助仓库，不属于基础设施交付的必需入口。

| 仓库 | 负责什么 | 什么时候查看或修改 |
| --- | --- | --- |
| [`platform-ops-toolkit`](https://github.com/ai-workspace-infra/platform-ops-toolkit) | 入口 Action、触发参数、流程编排、通用运维脚本 | 想启动一次运维任务，或修改流水线行为 |
| [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) | Terraform 模块、云资源、主机和环境资源声明 | 想创建/调整云资源、VPS、网络或 Terraform 配置 |
| [`playbooks`](https://github.com/ai-workspace-infra/playbooks) | Ansible Playbook，负责在主机上安装和配置具体 OS 应用 | 想修改服务安装、配置、部署或初始化逻辑 |
| [`gitops`](https://github.com/ai-workspace-infra/gitops) | GitOps 配置仓库，保存环境运行配置和发布后的目标状态 | 想修改环境配置、域名、服务参数或 GitOps 目标状态 |
| [`artifacts`](https://github.com/ai-workspace-infra/artifacts) | 可选的构建产物、镜像、压缩包或发布清单 | 当前发布流程需要复用或追溯构建产物时再查看 |

## 新人第一次使用：按这个顺序来

### 0. 先确认你要做的事情

- 只想了解流程：阅读本 README 和 [`platform-ops.yaml`](.github/workflows/platform-ops.yaml)。
- 想改云资源：去 `iac_modules`。
- 想改服务器上的应用安装或配置：去 `playbooks`。
- 想改某个环境的运行参数：去 `gitops`。
- 想查看或管理构建产物：按项目需要使用 `artifacts`；没有它也不影响本仓库作为运维入口使用。
- 想真正执行一次部署、扩容、迁移或恢复：回到本仓库的 **Actions** 页面，运行入口工作流。

不要把三个核心仓库的配置复制到本仓库；入口工作流会按 ref 将它们一起拉取。`artifacts` 是否参与某次发布，则取决于该发布流程是否需要对应的构建产物。

### 1. 准备 Vault Server

GitHub Actions 不直接保存云密钥、SSH 私钥和业务密钥。需要先准备一个已初始化、已解封，并且 GitHub Actions Runner 可以访问的 Vault Server。

当前默认地址是：[`https://vault.svc.plus`](https://vault.svc.plus)

如果使用其他地址，可以在手动运行工作流时填写 `vault_addr` 覆盖默认值。

### 2. 配置 GitHub Actions OIDC → Vault JWT

这是一次性初始化步骤，需要 Vault 管理员权限。脚本会创建 `sit`、`uat`、`prod` 三套独立的 policy 和 role，并限制 role 只能由允许的仓库工作流、分支或 tag 换取。

```bash
export VAULT_ADDR=https://vault.svc.plus
export VAULT_TOKEN="hvs.xxxxxxxxx"   # Vault 管理员 Token

chmod +x docs/tasks/vault_auth_split.sh
./docs/tasks/vault_auth_split.sh
```

初始化后执行布局校验：

```bash
./scripts/vault/vault_layout_verify.py
```

看到退出码为 `0` 才算通过。不要把 `VAULT_TOKEN` 提交到 Git 仓库，也不要把它填进 GitHub Actions 的 workflow input。

### 3. 填充 Vault 必需数据

流水线登录 Vault 后会读取以下几类路径：

| 类型 | 路径示例 | 用途 |
| --- | --- | --- |
| 公共 CI 凭据 | `kv/data/CICD` | 镜像仓库等公共服务凭据 |
| 环境基础凭据 | `kv/data/CICD/<env>` | `VULTR_API_KEY`、Terraform State、SSH 部署私钥 |
| 环境业务密钥 | `kv/data/<env>/*` | 数据库、Billing、代理等业务服务密钥 |

其中 `<env>` 是 `sit`、`uat` 或 `prod`。生产环境的 role 不允许删除 KV metadata；生产密钥建议由管理员或专门的密钥轮换流程维护。

### 4. 从 Actions 页面启动入口

打开本仓库的 **Actions → Deploy Environment & Provision Infrastructure → Run workflow**。

入口文件是：

```text
.github/workflows/platform-ops.yaml
```

第一次运行建议使用以下选择：

| 参数 | 新人建议 |
| --- | --- |
| `runner_type` | `ubuntu-latest` |
| `deploy_tag` | 使用已经存在的、不可变的镜像版本，例如 `daily-build-2026.07.30-r1` |
| `infra_ref` / `playbooks_ref` / `gitops_ref` | 三个仓库都使用相互匹配的 `main` 或发布 ref |
| `toolkit_ref` | 本仓库对应的发布 ref；留空默认 `main` |
| `target_domains` | 先选需要的业务域；首次验证可选单域，不建议直接 `all` |
| `cloud_provider` | 当前这条业务域链路实际只支持 `vultr-vps` |
| `vault_env_path` | 与目标环境一致：`sit`、`uat` 或 `prod` |
| `run_infrastructure` | 需要创建/更新主机时勾选 |
| `run_application_deploy` | 需要在主机上部署应用时勾选；必须同时勾选 `run_infrastructure` |
| `run_full_stack` | 从零创建环境时使用，会联动基础设施、应用部署和 DNS 发布 |

推荐的首次验证路径是：先只执行 Terraform/基础设施，再确认主机和 CMDB 正常，最后再执行应用部署。涉及生产 DNS 接管时，必须额外确认 `confirm_dns_switch`，不要在测试时勾选。

## 其他 Actions 入口

除了主入口 `platform-ops.yaml`，本仓库还有 4 个面向特定运维场景的工作流：

| 工作流 | 用途 | 如何使用 |
| --- | --- | --- |
| [`data-migration.yaml`](.github/workflows/data-migration.yaml) | 数据迁移、备份和恢复；支持 accounts 数据迁移和按业务域的 site migration | 可由 `platform-ops.yaml` 调用，也可以在 Actions 中手动运行；首次使用保持 `accounts_dry_run=true`，确认结果后再执行写入 |
| [`daily-main-snapshot.yaml`](.github/workflows/daily-main-snapshot.yaml) | 跨组织、跨仓库生成统一的 `daily-build-*` 快照 tag，并触发各仓库的构建/发布链路 | 默认按计划每天执行，也可以手动指定 `snapshot_tag`、source ref、环境和仓库列表；快照 tag 应作为后续部署的 `deploy_tag` |
| [`k6-performance-test.yaml`](.github/workflows/k6-performance-test.yaml) | 对指定环境执行 k6 压力测试，并将指标写入可观测性系统 | 仅支持手动运行；先用 `smoke`，确认目标 URL、环境和 Vault 凭据无误后，再使用 `capacity` 或更高 VU 数 |
| [`cron-rotate-domain-tls-certs.yaml`](.github/workflows/cron-rotate-domain-tls-certs.yaml) | 定期更新域名 TLS 证书，并将证书状态保存在 Vault | 默认每两个月自动运行，也可以手动运行；需要 Vault 中的 Cloudflare 凭据，生产 role 和域名范围必须先确认 |

这 4 个工作流与主部署链路的关系可以简单理解为：

```text
daily-main-snapshot.yaml  → 生成跨仓库 deploy_tag
                                ↓
platform-ops.yaml         → 资源 provision + 应用部署
                                ↓
data-migration.yaml       → 按需迁移 / 备份 / 恢复
k6-performance-test.yaml  → 部署后的性能验证
cron-rotate-domain-tls-certs.yaml → 独立的证书轮换维护
```

如果把项目切换到个人 GitHub 组织，这 4 个工作流也要一并检查硬编码的仓库、组织、Vault role、域名和可观测性地址。特别是 `daily-main-snapshot.yaml` 的组织矩阵、`k6-performance-test.yaml` 的 `playbooks` 仓库，以及证书轮换工作流使用的生产 Vault role，都不能直接沿用当前项目的值。

## 触发方式与环境

| 触发方式 | 默认环境 | 行为 |
| --- | --- | --- |
| Pull Request | `sit` | 校验和计划，不应作为生产发布入口 |
| `main` / `release/*` push | `uat` | 校验和计划 |
| `v*` tag | `prod` | 生产发布路径；生产 role 只接受版本 tag |
| `workflow_dispatch` | 手动选择 | 真正执行 provision、deploy、migration、backup、restore 等动作 |

当前业务域的端到端资源声明、基础凭据和主机路径仍以 `vultr-vps` 为准。虽然 `iac_modules` 已有 AWS、GCP、Azure 模块，但不能仅因为下拉框出现选项就认为 `platform-ops.yaml` 已经支持这些云。

## 一次运行实际发生什么

```text
Run workflow
    ↓
platform-ops-toolkit 读取参数并通过 OIDC 登录 Vault
    ↓
iac_modules 运行 Terraform，创建/更新资源并生成本次 CMDB
    ↓
playbooks 使用本次 CMDB，在主机上执行 Ansible 部署
    ↓
gitops 提供环境目标配置，必要时由流程提交或同步变更
    ↓
GitHub Actions 输出部署结果、日志和后续检查项
```

核心原则是：Terraform 先准备资源，Ansible 再使用同一次运行生成的 inventory；不要手工用旧 inventory 部署。

## 切换到个人项目时要修改什么

`.github/workflows/platform-ops.yaml` 当前是为 `ai-workspace-infra` 这套项目编排的。`web-saas`、`ai-workspace`、`agent-proxy`、`infra-platform` 等业务域名称，代表当前项目的实际业务系统，不是拿来即用的通用模块。

例如，工作流目前会调用：

| 当前绑定 | 在个人项目中需要怎么处理 |
| --- | --- |
| `ai-workspace-infra/iac_modules` | 换成个人项目的 Terraform/IAC 仓库，并保留工作流需要的目录结构、资源声明和输出 |
| `ai-workspace-infra/playbooks` | 换成个人项目的 Ansible 与可复用 Domain CD workflow 仓库 |
| `ai-workspace-infra/gitops` | 换成个人项目的 GitOps config 仓库；如果保留自动回写 tag，还要给它配置写权限 |
| `ai-workspace-infra/playbooks/.github/workflows/web-saas-domain-cd.yaml@main` | 换成个人项目对应的 reusable workflow；`ai-workspace`、`agent-proxy`、`open-platform` 等调用也要逐个替换 |
| `ai-workspace-xstream/xray-exporter`、`compassvpn/xray-exporter` | 如果个人项目使用自己的 exporter，修改 workflow input 的默认值或手动传入 `xray_exporter_release_repository` |
| `artifacts` | 按个人项目需要接入；只使用已有镜像/tag 时可以不接入 |

### 推荐的迁移步骤

1. 准备个人项目的 `platform-ops-toolkit`、`iac_modules`、`playbooks`、`gitops` 仓库。四个仓库不一定必须同名，但它们的职责和接口要对应；`artifacts` 仍然是可选的。
2. 在 `.github/workflows/platform-ops.yaml` 中替换所有硬编码的仓库和 owner。重点搜索并修改以下位置：

   ```text
   repository: ai-workspace-infra/iac_modules
   repository: ai-workspace-infra/playbooks
   repository: ai-workspace-infra/gitops
   uses: ai-workspace-infra/playbooks/.github/workflows/...@main
   owner: ai-workspace-infra
   ```

   `uses:` 的 reusable workflow 不能只改 checkout 的仓库；必须把每一个 `uses: ...playbooks/.github/workflows/...` 也改成个人项目的地址，并确保目标 workflow 仍然声明了相同的 `workflow_call` inputs 和 secrets。
3. 根据个人项目实际拥有的系统调整业务域。比如个人项目没有 `agent-proxy`，需要同步修改 `target_domains` 选项、Terraform 的 host/resource matrix、对应 job 的 `if` 条件、Vault 路径，以及 `playbooks` 中的域 CD workflow；仅把下拉框里的名称删掉是不够的。
4. 检查 `playbooks` 内部调用的应用仓库。`platform-ops.yaml` 负责调度域 workflow，具体的 Web SaaS、AI Workspace、Agent Proxy 应用仓库引用通常在 `playbooks` 或 GitOps 配置中；需要在那里把当前项目的 service repository、镜像 registry、部署 tag 和域名一起替换。
5. 重新配置 GitHub 权限：

   - 个人项目的 `platform-ops-toolkit` 必须能读取 `iac_modules`、`playbooks` 和 `gitops`。
   - 被 `uses:` 调用的 reusable workflow 必须对调用仓库可见；跨组织或私有仓库时，还要确认 Actions 的访问策略。
   - 自动更新 `gitops` tag 的 job 需要对个人项目的 `gitops` 有写权限。当前 workflow 使用 GitHub App token，并将 owner 固定为 `ai-workspace-infra`；迁移后要重新安装 App、修改 owner，或改用存放在 Vault 的最小权限 fine-grained token。
6. 重新配置 Vault，不要直接复用当前项目的 role：

   - 修改 [`vault_auth_split.sh`](docs/tasks/vault_auth_split.sh) 中的 `REPO`、`PLAYBOOKS_REPO` 和 workflow allowlist。
   - 为个人项目创建新的 policy/role；role 的 `repository` 和 `job_workflow_ref` 必须绑定个人项目，不能继续绑定 `ai-workspace-infra/platform-ops-toolkit`。
   - 按个人项目重建 `kv/data/CICD/<env>`、`kv/data/<env>/*`、域名证书和云账号凭据，并运行 `vault_layout_verify.py`。
7. 最后用 `workflow_dispatch` 做一次单域、非生产的 Terraform plan，再做应用部署验证。确认 Vault、IAC、Playbooks、GitOps、镜像/tag 和 DNS 都属于同一个个人项目后，再启用 `all` 或生产 tag 发布。

可以先用下面的搜索确认是否还有当前项目的绑定残留：

```bash
rg -n 'ai-workspace-infra|ai-workspace-xstream|compassvpn|svc\.plus|onwalk\.net' \
  .github docs config scripts
```

## 常见问题

### 我应该改哪个仓库？

改云资源去 `iac_modules`，改 OS/应用部署去 `playbooks`，改环境目标配置去 `gitops`；只有要改入口参数、流程编排或通用运维脚本时才改本仓库。

### Actions 里找不到 Run workflow？

确认你有仓库的 Actions 使用权限，并且工作流文件已经存在于当前分支。只有 `workflow_dispatch` 工作流才能从 Actions 页面手动启动。

### Vault 返回 403 或 permission denied？

先检查 `VAULT_ADDR`、OIDC/JWT auth method 和 role 是否已执行初始化脚本；再确认 `vault_env_path` 与目标环境一致，以及生产运行是否使用 `v*` tag。最后运行 `./scripts/vault/vault_layout_verify.py`。

### 为什么选择 AWS/GCP/Azure 后失败？

这是预留的多云选项。目前 `platform-ops.yaml` 这条业务域交付链路只完成了 `vultr-vps` 的端到端接线，工作流会有意快速失败，避免把资源部署到错误的云上。

### 部署成功但应用不对？

检查四个仓库使用的 ref 是否匹配，尤其是 `deploy_tag`、`playbooks_ref` 和 `gitops_ref`。再检查目标域、Vault 环境路径、DNS 和 GitOps 配置是否属于同一个环境。

## 进一步阅读

- [Vault 鉴权与策略隔离](docs/vault/vault_authentication_and_policy_isolation.md)
- [Vault KV 三层模型](docs/vault/kv_tier_model.md)
- [多环境交付标准](docs/standards/multi-environment-delivery-and-release-standard.md)
- [业务域文档](docs/domains/README.md)
- [入口工作流](.github/workflows/platform-ops.yaml)
