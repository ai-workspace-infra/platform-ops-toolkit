# Daily Snapshot：不可变 Tag 与最新成功快照

本文持续记录 `Daily Main Snapshot` 的调试过程、设计边界、代码变更和验收结果。
目标是让每天产生的跨仓快照可追溯、可重试，并能可靠选出最新一套构建成功的
快照点。

## 1. 当前目标

- 所有 Git tag 保持不可变。
- `--ref` 明确新 tag 从哪个 ref 获取提交 SHA，默认值仍为 `main`。
- `--apply --ref main` 创建指向各仓库当前 `main` SHA 的新 tag，但不移动同名旧 tag。
- 同一天需要重试时使用 `-r1`、`-r2` 等新 tag。
- 构建等待同时匹配 tag 名和 SHA，不能误用同名 tag 的历史 CI run。
- 环境看板和部署入口最终选择“整套构建成功且时间最新”的不可变快照。

## 2. 核心语义

| 概念 | 语义 |
|---|---|
| 快照 tag | 不可变；创建后永远指向同一个提交 |
| `--ref REF` | 指定创建新 tag 时解析 SHA 的来源 |
| `--apply` | 执行缺失 tag 的创建，不允许强制移动旧 tag |
| 重试 tag | 使用 `daily-build-YYYY.MM.DD-rN` 创建新的不可变快照 |
| 最新成功快照 | 从历史不可变 tag 中派生选择，不使用可变 Git tag 充当指针 |

推荐命令：

```bash
bash docs/tasks/tag-ai-workspace-mains.sh \
  --tag daily-build-2026.07.29-r1 \
  --apply \
  --ref main \
  --build
```

如果 `daily-build-2026.07.29-r1` 已存在且指向其他 SHA，脚本必须跳过并提示改用
下一个重试 tag，不能修改已有 ref。

## 3. 已观察到的问题

### 3.1 同名 tag 导致旧构建被重复读取

调试 GitHub Actions run：

- `ai-workspace-infra/platform-ops-toolkit` run `30434176735`
- 之前关联失败的服务 run：
  - `portal`：`30382976468`
  - `postgresql.svc.plus`：`30382986739`

原等待脚本只使用 `headBranch == snapshot_tag` 查找 run。同一个 tag 已有历史运行时，
当天重跑会立即命中旧 run，因此持续报告旧失败，无法判断当前目标 SHA 是否产生了
新构建。

修正原则：

- 先通过仓库 API 把快照 tag 解析成目标 commit SHA。
- 查找 CI run 时同时要求：
  - `event == push`
  - `headBranch == snapshot_tag`
  - `headSha == expected_sha`

这样可以避免 tag 名相同但提交或运行不匹配的假结果。

### 3.2 `--ref` 与 tag 可变性被混为一谈

一度考虑让 `--apply --ref main` 强制移动同名 tag，以便当天重跑。该方案与制品
可追溯性冲突，现已放弃。

最终边界：

- `--ref` 只控制新 tag 的来源。
- 已存在 tag 不允许移动。
- 失败重试创建新 tag。

## 4. 本轮代码变更

### `docs/tasks/tag-ai-workspace-mains.sh`

- 新增 `--ref REF` 参数。
- 默认 source ref 为 `main`，保持原有调用兼容。
- SHA 查询从固定 `commits/main` 改为 `commits/${SNAPSHOT_REF}`。
- dry-run 输出所选 ref 对应的计划 SHA。
- 同名 tag 指向不同 SHA 时保持 `SKIP`。
- 跳过提示中给出 `TAG-r1` 的不可变重试建议。
- help 明确 `--ref` 不会移动已有 tag。

### `.github/scripts/tag-daily-main-snapshot.sh`

- 每日任务显式传入 `--ref main`。
- tag 仍由 `daily-build-YYYY.MM.DD` 或 `SNAPSHOT_TAG` 决定。
- 同一天基础 tag 已存在时，不自动修改它。

### `.github/scripts/wait-daily-snapshot-builds.sh`

- 等待前解析当前快照 tag 的 commit SHA。
- CI run 查询增加 `headSha` 条件。
- 无法解析 tag 时记录 `build_lookup_failed`。
- 超时时记录预期 SHA，方便继续定位。

### `docs/daily-snapshot-manual.md`

- 补充不可变 tag 约束。
- 补充 `--apply --ref main` 示例。
- 补充 `-r1`、`-r2` 重试约定。
- 明确看板和部署端应选择最新成功快照。

## 5. 已完成验证

已执行：

```bash
bash -n \
  docs/tasks/tag-ai-workspace-mains.sh \
  .github/scripts/tag-daily-main-snapshot.sh \
  .github/scripts/wait-daily-snapshot-builds.sh

git diff --check
```

结果：

- Shell 语法检查通过。
- Git diff 空白检查通过。
- 尚未执行会创建远端 tag 或触发构建的破坏性验证。

## 6. 最新成功快照的选择规则

“最新”不能只按 tag 名、tag 创建时间或单个镜像是否存在判断。候选快照必须同时满足：

1. tag 符合目标环境和快照命名规则。
2. 所有必需服务都存在该 tag 对应的 CI run。
3. 每个 run 的 `headSha` 与该仓库 tag 当前解析 SHA 一致。
4. 所有必需 run 均为 `success`。
5. 所需 `release-manifest.json`、镜像 tag 或其他制品均存在。
6. 在满足以上条件的候选中选择创建时间最新的一组。

当前 workflow 已记录单次快照的逐仓状态，但还没有持久化的“全套服务最新成功快照”
索引。后续实现时应从状态制品或 GitHub API 计算该结果，而不是创建一个可移动的
`latest` Git tag。

## 7. 后续工作

- 为当天自动重试设计统一的 `-rN` 分配方式，避免四个 organization matrix job
  各自计算出不同后缀。
- 增加全局汇总 job，只有所有必需服务均成功时才登记该 tag 为成功快照。
- 将最新成功快照写入组织 README 使用的数据文件或其他可审计索引。
- 验证更新后的等待脚本不会读取旧 run，并对 `-r1` 实际跑一次端到端构建。
- 完成验证后提交 PR，保留本文件作为后续调试和验收记录。

## 8. 变更日志

### 2026-07-29

- 确认 tag 必须不可变。
- 新增 `--ref`，仅用于选择新 tag 的 source SHA。
- 每日任务显式使用 `--ref main`。
- CI run 匹配增加目标 SHA 条件。
- 明确失败重试使用 `-rN` 新 tag。
- 记录“最新成功快照”仍需全局汇总索引，不能用移动 tag 替代。

### PR 验证记录

- PR #175：`fix(daily-snapshot): keep immutable tags and match latest build SHA`
- commit：`7149f26`
- `Sec QA Gate (gitleaks)`：通过。
- `Workflow Gating Verify`：失败，报告 `platform-ops.yaml` 调用了
  `playbooks/.github/scripts/domain-cd-observe-endpoints.sh`，但本仓检查器将其判断为
  未在当前仓库跟踪。该脚本实际属于 `ai-workspace-infra/playbooks` 仓库，属于已有的
  跨仓 workflow gating 规则问题，与本次快照脚本改动无直接关系。
- `Deploy Environment & Provision Infrastructure`：本次验证仍在执行基础设施部署链路，
  其余依赖 job 因前置条件未满足而跳过。
