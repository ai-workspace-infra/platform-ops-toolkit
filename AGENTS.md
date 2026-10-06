# platform-ops-toolkit Agent 约束：只做控制面

本文件是仓库根级强制规则。四边界完整判定见
[`execution-ownership-migration`](https://github.com/ai-workspace-lab/xworkspace-core-skills/blob/main/skills/engineering-standards/execution-ownership-migration/SKILL.md)。

## 必须归 Toolkit 的内容

- GitHub Actions 入口和 `workflow_dispatch`/`workflow_call` 输入校验；
- 环境、目标和不可变 tag/SHA 选择；审批、Vault/OIDC 授权和精确 workflow allowlist；
- 调用固定 SHA 的 Playbooks/IaC reusable workflow；关联、等待、证据来源和 checksum/digest 校验；
- 最终放行、停止、回滚决策和脱敏发布证据。

## 新代码硬禁令

`.github/scripts`、Actions、控制器不得新增或扩展以下执行：`ssh`、`scp`、`ansible*`、`docker`
（仅允许受控镜像元数据只读校验）、`systemctl`、`apt-get`、`psql`、`pg_dump`、`pg_restore`、
`terraform`、`gcloud`、`aws`、`wrangler`、Cloudflare/DNS API 变更。不得直接写主机、服务、
数据库、DNS、云资源或 CMDB。执行逻辑必须迁移到对应 owner，再切换调用方。

现有 `.github/scripts/` 遗留候选由 `scripts/ci/script_ownership_verify.py` 冻结；历史登记不是新增逻辑豁免。
任何新增执行标记、修改冻结脚本或绕过 scanner 的 PR 必须失败。

## PR 必须证明

`owner`、`caller`、副作用边界、固定 SHA、证据来源，以及“新增 owner → 切换 caller → 验证 → 删除旧副本”。
没有真实 UAT 证据时不得声称部署/迁移/回滚完成。
