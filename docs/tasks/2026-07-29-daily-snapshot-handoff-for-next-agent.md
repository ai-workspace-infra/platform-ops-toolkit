# Daily Snapshot 交接说明

本文面向后续接手的 agent，目的是把当前 `Daily Main Snapshot` 相关工作状态、
已完成修改、未完成项和后续执行顺序集中记录，避免重新翻找对话历史。

## 1. 当前任务目标

目标不是把 tag 变成可移动指针，而是让系统能稳定地做以下事情：

- 通过 `workflow_dispatch` 或 CLI 指定一个 `ref`，从该 ref 解析 source SHA。
- 用这个 SHA 创建新的不可变快照 tag。
- 当同名 tag 已存在时，不修改旧 tag，而是建议使用新的 `-rN` tag 重试。
- 触发各服务仓库按同名 tag 构建镜像，并等待最新成功 run。
- 后续再把“按环境自动展示最新发布”的 README 仪表盘接上。

## 2. 当前进度

### 已完成

- `docs/tasks/tag-ai-workspace-mains.sh`
  - 支持 `--ref REF`。
  - 默认 `SNAPSHOT_REF=main`。
  - 只从 `REF` 解析 source SHA，不允许移动已有 tag。
  - 同名 tag 冲突时保持跳过，并提示用 `TAG-r1` 之类的新 tag 重试。
- `.github/scripts/tag-daily-main-snapshot.sh`
  - 从 `SNAPSHOT_REF` 读取 source ref。
  - 不再固定写死 `--ref main`。
  - 保持每日快照流程异步触发构建。
- `.github/workflows/daily-main-snapshot.yaml`
  - `workflow_dispatch` 新增 `ref` 输入。
  - 通过 `SNAPSHOT_REF` 传给打 tag 脚本。
- `docs/daily-snapshot-manual.md`
  - 补了 `workflow_dispatch` 的 `ref` 用法。
  - 增加了 `sit` / `uat` / `prod` 的推荐填写表。
  - 明确 `ref` 只影响新 tag 的 source SHA。
- `docs/tasks/2026-07-29-daily-snapshot-immutable-tag-and-latest-success.md`
  - 作为主调试记录持续更新中。

### 已验证

- `bash -n` 通过：
  - `.github/scripts/tag-daily-main-snapshot.sh`
  - `docs/tasks/tag-ai-workspace-mains.sh`
  - `.github/scripts/wait-daily-snapshot-builds.sh`
- `git diff --check` 通过。
- 相关改动已提交并推送到现有 PR 分支。

## 3. 当前仓库状态

- 当前工作分支：`fix/daily-snapshot-shared-github-repo-and-exec-bit`
- 最近提交：`1e3f510 feat: expose snapshot ref in workflow dispatch`
- 现有 PR：`https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/175`

## 4. 关键文件

- [`.github/workflows/daily-main-snapshot.yaml`](/Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit/.github/workflows/daily-main-snapshot.yaml)
- [`.github/scripts/tag-daily-main-snapshot.sh`](/Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit/.github/scripts/tag-daily-main-snapshot.sh)
- [`docs/daily-snapshot-manual.md`](/Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit/docs/daily-snapshot-manual.md)
- [`docs/tasks/2026-07-29-daily-snapshot-immutable-tag-and-latest-success.md`](/Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit/docs/tasks/2026-07-29-daily-snapshot-immutable-tag-and-latest-success.md)
- [`docs/tasks/tag-ai-workspace-mains.sh`](/Users/shenlan/workspaces/ai-workspace-infra/platform-ops-toolkit/docs/tasks/tag-ai-workspace-mains.sh)

## 5. 已知事实

- tag 必须保持不可变。
- `--ref` 只负责选择 source SHA，不负责重定向旧 tag。
- `workflow_dispatch.ref` 只是在 UI 层补齐同一语义。
- `daily-build-YYYY.MM.DD` 这种 tag 仍然是正确的 Git / image tag 形式。
- 之前 PostgreSQL 的失败是 Helm chart version 里不能直接塞 `07` 这种带前导零的数字段，不是 Git tag 规则本身的问题。

## 6. 仍待处理

### 高优先级

- 把“按环境自动拉取最新包版本”的 README 仪表盘做出来。
- 让 README 顶部的卡片按 `sit` / `uat` / `prod` 展示最新发布入口。
- 让每个环境卡片只显示真正属于该环境的最新镜像，避免三栏重复。

### 中优先级

- 继续确认服务仓库里的 workflow 是否都已统一成“tag push -> 同名镜像 tag”。
- 如果仍有服务使用 `workflow_dispatch`，需要确保它们读取显式 `deploy_env`，而不是只靠 tag 推断。
- 为 `postgresql.svc.plus` 的 release manifest version 规则补一个不冲突的规范化方式。

## 7. 推荐的下一步顺序

1. 先确认 PR #175 上这次 `ref` 输入的改动是否需要再跑一次 workflow 校验。
2. 再回到 README 仪表盘需求，补自动化生成脚本或数据源。
3. 如果要继续打每日快照，优先用 `--apply --ref main` 或 `workflow_dispatch.ref=main` 做一次最小端到端验证。
4. 发现新失败时，先分清是 tag 选择问题、workflow_dispatch 传参问题，还是服务仓库的构建产物命名问题。

## 8. 交接备注

- 这条线索的核心不是“改成可变 tag”，而是“永远根据不可变 tag 选出最新成功快照”。
- 后续所有 README 展示、环境 badge、制品列表，都应该基于这个不可变快照模型来做。
- 如果继续碰到构建失败，优先看服务仓库里的 `chart version`、`release manifest` 和 `workflow_dispatch` 参数名是否一致。

