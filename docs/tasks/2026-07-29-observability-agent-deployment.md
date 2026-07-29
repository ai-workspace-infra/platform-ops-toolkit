# 监控 Agent 自动部署功能交付报告

按照您的要求，我已经将监控 Agent（包括探针、汇总转发端以及 DeepFlow）聚合为单一的 playbook 并接入到 `platform-ops-toolkit` 自动化流水线中。相关 PR 已经通过自动化审查并直接合并到了各自仓库的 `main` 分支。

## 🛠 修改与聚合内容

### 1. Playbooks 整合 (`ai-workspace-infra/playbooks`)
新增了 `deploy_observability_agent.yml`，将原本分散的监控逻辑聚合为一条完整部署流：
- **DeepFlow Agent**: 按需调用 `charts/observability-agent` 角色。
- **基础探针**: 默认加载 `vhosts/node_exporter` 和 `vhosts/process_exporter`。
- **业务探针**: 引入自动化判断逻辑，通过 `pgrep -x xray` 检查，仅在存在 xray 服务时部署 `vhosts/xray-exporter`。
- **数据汇总**: 统一部署 `vhosts/vector-agent`。
- **动态配置**: 更新了 Vector 的模板 `vector.toml.j2`，将之前写死的端点替换为动态变量 `vector_observability_endpoint`。

👉 *相关 PR 已合并*：[Pull Request #205](https://github.com/ai-workspace-infra/playbooks/pull/205)

### 2. 流水线任务组装 (`ai-workspace-infra/platform-ops-toolkit`)
更新了主部署流水线 `platform-ops.yaml`：
- **入参扩展**: 在 `workflow_dispatch` 菜单中新增了 `observability_endpoint`，默认指向 `https://observability.svc.plus`，支持手动覆盖。
- **并行任务**: 新增 `deploy_monitor_agent` 任务。它会在 `deploy_base` 完成系统基础准备后立即执行（与其他业务服务的部署任务并行）。
- **Vault 联动**: 自动连接 `kv/data/CICD/observability` 路径，提取 `user` 与 `password` 凭据，并注入给 Vector Agent 的认证模块。
- **脚本封装**: 新增 `platform-ops_deploy_monitor_agent.sh` 执行外置调用逻辑，维持了 YAML 文件的整洁度。

👉 *相关 PR 已合并*：[Pull Request #181](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/181)

## 🧪 验证建议
代码已合并至 `main`。您现在可以直接去 GitHub Actions 控制台触发一次 `platform-ops.yaml` 的完整环境拉起或增量部署：
1. 观察 `Deploy Monitor Agent` 节点是否正常被触发。
2. 观察控制台，确认 Vault 证书拉取与 playbook 注入是否符合预期。
3. 前往 `observability.svc.plus` 面板，确认对应主机的探针数据和日志是否成功流入！
