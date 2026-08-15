# UAT Bootstrap / Gate 运行时问题记录

## 已确认问题

本轮 UAT run `30789030414` 暴露了两个相互独立的问题：

1. Console Bootstrap 约 13 分 52 秒。只读检查发现 `apt-listchanges.service` 长时间处于 `activating`，与 Docker 包安装争用系统包管理状态。
2. Agent Proxy Gate 在 `community.hashi_vault.vault_write` 失败。Runner 已安装 Ansible 与 `community.hashi_vault` collection，但 Python 环境缺少 `hvac`，导致生成的 Xray UUID 无法安全写回 Vault。

## 修复边界

- apt 背景任务与锁等待修复位于 `ai-workspace-infra/playbooks#241`，只影响 Docker 主机初始化，不永久关闭系统 timer，也不手工修改 UAT 主机。
- Runner 依赖修复位于本仓库：`setup-deployment-runner` 将 `hvac` 与 Ansible 一次安装，避免到 `[3] Agent Proxy` 阶段才失败。

## 验收标准

- `[2] DB Init`：`Create Web SaaS databases and roles` 与 `Initialize Web SaaS baseline schemas` 均成功。
- `[3] Agent Proxy`：Vault UUID 写回不再报 `Failed to import ... hvac`，随后 native services verify 通过。
- Console Bootstrap 不再因正在运行的 `apt-listchanges.service` 长时间等待。
- 全流程仍保持 UAT-only，不访问生产节点，不直接修改生产数据。
