# P0a：Observability 本地 Grafana 健康检查归属迁移

## 基线与范围

- Toolkit 基线：`5d14ee4dad9369896d06745abdcee5e7de6728b1`。
- Playbooks owner：[PR #569](https://github.com/ai-workspace-infra/playbooks/pull/569)，已合并，固定 SHA `49b37d3a7d35610282f5986367c3853158660457`。
- 本批仅迁移 `observability-server.yml` / `deploy_shared_target` 部署后的本地 Grafana 检查。
- Toolkit 控制入口、环境、顺序和证据身份；Playbooks Role 在明确 inventory host 上执行服务检查。GitOps 与 IaC 边界不变。

## 四阶段记录

1. **新增 Role：完成。** 扩展 `docker/observability_server_operations` 的 `verify_local_grafana`，不执行部署 tasks；显式 inventory、单 host、UAT-only、HTTP 200 和 JSON `database=ok`，有界重试、禁止重定向/代理、隐藏响应正文。
2. **切换 Toolkit 调用：完成。** [PR #1271](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1271)，合并 SHA `a4d3217e5558bf03798c1e79457f1f72164f1e26`。独立 checkout 固定 owner SHA，不改变部署所用 `source_ref`；传入原 access inventory/node，调用前核对 checkout SHA。成功摘要记录 owner SHA、Toolkit SHA 和 node；失败不产生成功摘要，无静默回退。
3. **验证：本地和 PR CI 非变更演练通过。** Owner 16 项测试及 Ansible syntax-check 通过；Toolkit 5 项测试运行真实 workflow command 与固定 SHA Role，使用 loopback HTTP fixture。覆盖成功、数据库故障、错误 SHA/目标与摘要门禁。workflow gating（39 个 workflow）、Observability OIDC 契约、`git diff --check` 通过。
   - Owner main CI：[37214692473](https://github.com/ai-workspace-infra/playbooks/actions/runs/37214692473)，成功。
   - Toolkit 调用方 CI：[37215024197](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37215024197)，Workflow Gating Verify 与安全检查成功；部署等 runtime jobs skipped。
4. **删除旧副本：本清理 PR。** 在调用方合并和 CI 演练通过后删除旧内联 `ansible -m uri | grep`，保留纯控制面的部署摘要，新增防止旧 probe 重回 Toolkit 的断言。清理后 Toolkit 路由测试共 6 项。

## 授权和证据限制

- 没有触发真实 UAT/PROD、DNS、云资源操作或数据迁移；CI 绿色不是真实 UAT 晋级证据。
- Workflow filename、Vault job 和 OIDC 权限未改变；无新增 Vault allowlist。
- 本操作只证明本地 Grafana 健康，不证明 TLS、公网路径、历史数据或整个 Observability 栈健康。
- 原工作区和无关改动不动，使用基于最新远端 main 的独立 worktree。

## 下一批

- P0b：剩余 Observability 公网/Shared readiness 服务检查，先扩展 Playbooks Role，再切各调用方；路由/TLS 行为差异须先测试，不顺带放宽门禁。
- P1：Caddy 证书恢复 Role → 两个 Toolkit 调用方 → 验证 → 删除旧脚本。
- P2：复用/扩展 IaC 临时 GCP access/CMDB executor，收敛 Observability、node-access-gcp、AI Aggregator；不混入目录改名。
- 后续 DNS 对账、XConnect、SMTP/服务凭据和间接执行链继续分批，不扩大本 PR 范围。
