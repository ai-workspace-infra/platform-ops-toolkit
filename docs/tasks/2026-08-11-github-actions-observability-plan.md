# GitHub Actions CI/CD 可观测性计划草案

> 状态：调研完成，计划草案
> 记录日期：2026-08-11
> 目标：基于 `promhippie/github_exporter`、现有 PostgreSQL、Prometheus/VictoriaMetrics 和 Grafana，形成跨组织 CI/CD 流水线状态与 DORA 指标看板。

## 1. 背景

当前每日 snapshot workflow 会跨多个组织、多个仓库并行创建和构建同一个 snapshot。一次父 workflow 可能出现：

- 部分组织构建成功；
- 某个下游仓库构建失败；
- 父 workflow 的统一汇总 job 仍然成功完成，但整体结论为失败。

例如 [Daily Main Snapshot run 31440755720](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31440755720) 中，`ai-workspace-infra` fan-out 失败，而其他组织 fan-out 成功。仅看 GitHub Actions 的单个 workflow 结果，不足以表达 snapshot 矩阵、仓库级失败原因和最终发布状态。

## 2. 目标与非目标

### 2.1 目标

1. 汇总四个组织及相关仓库的 workflow run/job 状态。
2. 展示最新 snapshot、CI build、CD deployment 的成功、失败、进行中和跳过状态。
3. 统计失败率、运行耗时、排队耗时、job 耗时和构建分钟数。
4. 逐步形成 DORA 指标：Deployment Frequency、Lead Time for Changes、Change Failure Rate、MTTR。
5. 使用现有 PostgreSQL 持久化原始 workflow 事件，不引入 Supabase。
6. 使用现有 Prometheus/VictoriaMetrics 和 Grafana 作为指标查询与展示基础。

### 2.2 非目标

- 不把普通 CI 构建失败直接当作生产变更失败。
- 不用 GitHub-hosted runner exporter 伪造主机 CPU、磁盘和进程指标。
- 不把 CI/CD 观测数据写入 Billing、Accounts 或其他业务数据库。
- 不在 `platform-ops-toolkit` 中重新实现业务仓库的构建和部署逻辑。
- 不直接改造依赖 Cloudflare + Supabase 的现成 Workflow Metrics 应用。

## 3. 现状与边界

领域边界遵循 [`DELIVERY-MANIFEST.md`](../domains/DELIVERY-MANIFEST.md)：

- 服务 CI Build 属于各服务开发仓库；
- 域 CD 属于 `playbooks` 仓库的域 CD workflow；
- `platform-ops-toolkit` 负责基础设施编排、snapshot 和跨组织汇总；
- Grafana、VictoriaMetrics、PostgreSQL 等基础设施属于 `open-platform` 域。

当前 observability 配置已经启用 Prometheus、VictoriaMetrics、VictoriaLogs 和 VictoriaTraces，但 Grafana 仍为 disabled，见 [`observability-stack/values.yaml`](../../../gitops/services/observability/observability-stack/values.yaml)。

本计划使用 `open-platform` 域已有 PostgreSQL 实例中的独立数据库或独立 schema，不使用 Web SaaS 的业务 PostgreSQL。

## 4. 推荐架构

```text
GitHub Organization Webhooks
  ├─ workflow_run
  └─ workflow_job
          │
          ▼
promhippie/github_exporter v18.x
  ├─ PostgreSQL store: workflow_runs / workflow_jobs
  ├─ /metrics
  └─ /github webhook endpoint
          │
          ├─ Prometheus scrape
          │       ▼
          │   VictoriaMetrics
          │       ▼
          │   Grafana dashboards / alerts
          │
          └─ DORA aggregation layer
                  ├─ CI/CD raw events in PostgreSQL
                  ├─ PR merge / commit enrichment
                  ├─ deployment environment classification
                  └─ DORA recording metrics
```

`promhippie/github_exporter` 当前版本已经提供 PostgreSQL store，并通过迁移创建 `workflow_runs` 和 `workflow_jobs` 表。它可以启用 workflow run、workflow job、runner 和 billing collectors，并通过 GitHub Webhook 接收实时事件：

- [GitHub Exporter](https://github.com/promhippie/github_exporter)
- [PostgreSQL store](https://github.com/promhippie/github_exporter/blob/main/pkg/store/postgres.go)
- [Workflow run collector](https://github.com/promhippie/github_exporter/blob/main/pkg/exporter/workflow_run.go)
- [Workflow job collector](https://github.com/promhippie/github_exporter/blob/main/pkg/exporter/workflow_job.go)

## 5. PostgreSQL 方案

### 5.1 数据库隔离

建议创建：

```text
database: github_actions_observability
role: github_actions_exporter
schema: public（第一阶段）或 ci_observability（后续）
```

该账号只拥有观测数据库的连接、建表、读写和迁移权限，不应拥有其他业务数据库权限。

Exporter DSN 使用 PostgreSQL 连接串，例如：

```text
postgres://github_actions_exporter:<password>@<postgres-host>:5432/github_actions_observability?sslmode=verify-full
```

生产环境凭据应通过 Vault 在运行时注入；不放入 Git、GitHub Actions Secrets 或公开的 Helm values。跨主机连接沿用现有 PostgreSQL TLS tunnel 和证书链路。

### 5.2 原始数据表

第一阶段直接使用 exporter 自带表：

| 表 | 用途 |
| --- | --- |
| `workflow_runs` | workflow 的创建、启动、更新时间、分支、SHA、状态、run number |
| `workflow_jobs` | job 的创建、启动、完成时间、结论、runner、runner group、labels |

第二阶段补充自有表，避免把 DORA 语义硬编码到 exporter 的原始表中：

```text
ci_delivery_events
  id, org, repo, workflow, run_id, environment,
  deploy_tag, sha, status, started_at, completed_at,
  is_production, source

ci_change_events
  id, repo, pr_number, merge_sha, merged_at,
  first_commit_at, author

ci_incidents
  id, environment, service, started_at,
  recovered_at, source, run_id
```

## 6. 指标定义

### 6.1 第一阶段指标

#### 流水线状态

- 最新 workflow 状态：queued、in_progress、success、failure、cancelled、skipped。
- 最新 snapshot 的组织 fan-out 矩阵。
- 最新 snapshot 的仓库级构建矩阵。
- CD workflow 的环境级状态：SIT、UAT、PROD。

#### 失败率

```text
workflow failure rate = failed completed runs / all completed runs
job failure rate      = failed completed jobs / all completed jobs
```

按以下维度聚合：

```text
organization, repository, workflow, environment, branch, event
```

重试 run、取消 run、人工跳过 job 应单独分类，不直接并入失败。

#### 耗时

- workflow total duration：`started_at → updated_at/completed_at`。
- job execution duration：`started_at → completed_at`。
- queue duration：`created_at → started_at`。
- snapshot fan-out duration：父 workflow 开始时间 → 汇总 job 完成时间。

#### 构建分钟数

同时保留两种口径：

1. `execution_minutes`：各 job 实际执行分钟数之和。
2. `billable_minutes`：GitHub Actions 计费 API 返回的计费分钟数。

两者不能混用。`workflow_jobs` 可以计算执行分钟数；GitHub billing collector 可提供当前账单使用量，但月度历史计费趋势可能仍需要额外抓取和落库。

### 6.2 DORA 指标

#### Deployment Frequency

只统计成功的部署事件，不统计普通 build：

```text
production deployment count / time window
```

必须能识别：

- workflow 属于 CD，而非 CI；
- `environment=prod`；
- 使用的 `deploy_tag`；
- 部署是否真正完成。

当前交付契约要求 CD 显式消费 `deploy_tag`，因此 `deploy_tag`、SHA 和 environment 必须进入 `ci_delivery_events`。

#### Lead Time for Changes

```text
production deployment completed_at - change merged_at
```

需要通过 `merge_sha` 关联 PR merge 时间、commit 时间和最终生产部署 SHA。仅依赖 exporter 的 `workflow_runs.sha` 不足以得到完整 Lead Time。

#### Change Failure Rate

```text
failed production deployments / all production deployments
```

失败生产部署必须来自 CD/deployment 事件；`billing-service` 的 CI build failure 只能计入 CI failure rate，不能直接计为 Change Failure Rate。

#### MTTR

优先使用事故事件：

```text
incident recovered_at - incident started_at
```

如果暂时没有事故系统，可以先提供近似指标：

```text
next successful production deployment - failed production deployment
```

该指标必须在 Dashboard 中标记为 `deployment recovery time`，不能冒充完整 MTTR。

## 7. Grafana Dashboard 草案

### Dashboard A：CI/CD Overview

- 当前 PROD/UAT/SIT 发布状态
- 最新 snapshot 总状态
- 四组织 fan-out 状态矩阵
- 最近失败仓库和失败 job
- 失败 run 直达 GitHub 链接

### Dashboard B：Pipeline Reliability

- 过去 24 小时、7 天、30 天失败率
- 按组织、仓库、workflow 分组的失败率
- P50/P95 workflow duration
- P50/P95 queue duration
- 取消、跳过和重试比例

### Dashboard C：Build Cost and Capacity

- execution minutes
- billable minutes
- 按仓库、workflow、runner type 的分钟数
- GitHub-hosted 与 self-hosted runner 对比
- 高耗时 workflow Top N

### Dashboard D：DORA

- Deployment Frequency
- Lead Time for Changes
- Change Failure Rate
- MTTR / deployment recovery time
- 按环境和服务筛选

## 8. 安全与可靠性要求

1. 使用 GitHub App，不使用长期 PAT 作为默认方案。
2. GitHub App 仅授予所需组织/仓库的 Actions read 权限；Webhook 也使用最小权限。
3. Exporter 的 webhook endpoint 必须通过 HTTPS、签名验证和反向代理暴露。
4. GitHub App 私钥、Webhook secret、PostgreSQL 密码全部由 Vault 注入。
5. 不把 `run_id`、完整 SHA、PR 标题等高基数字段无限制写入 Prometheus labels。
6. 原始明细保留在 PostgreSQL，Prometheus/VictoriaMetrics 只保留适合查询和告警的 recording metrics。
7. Workflow Webhook 事件需要补偿机制：定期使用 Actions API 校验最近窗口，修复 webhook 丢失或 exporter 重启造成的缺口。
8. Grafana 启用前确认它属于 `open-platform` 域，并按现有 CD 入口交付。

GitHub 官方说明 `workflow_run` 和 `workflow_job` Webhook 可分别接收 workflow 和 job 活动，GitHub App 需要 Actions read 权限：[Webhook events](https://docs.github.com/en/webhooks/webhook-events-and-payloads)、[Actions permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps)。

## 9. 分阶段实施计划

### Phase 0：契约和访问验证

- 确认 `open-platform` PostgreSQL 实例、TLS tunnel 和独立数据库承载位置。
- 创建 Vault 读取路径、PostgreSQL role 和 GitHub App 权限清单。
- 确认四个组织的 webhook 管理范围。
- 固化 CI、CD、snapshot、environment 和 production 的分类规则。

### Phase 1：Exporter 和原始流水线指标

- 部署 `promhippie/github_exporter`。
- 启用 PostgreSQL store、workflow runs、workflow jobs、billing collector。
- 配置组织级 `workflow_run` / `workflow_job` Webhook。
- 接入 Prometheus/VictoriaMetrics。
- 验证当前类似 [run 31440755720](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/31440755720) 的父 workflow、fan-out job 和下游 run 均能被记录。

### Phase 2：Grafana 基础 Dashboard

- 启用并部署 Grafana。
- 建立 CI/CD Overview、Pipeline Reliability、Build Cost 三个 Dashboard。
- 增加失败、长耗时、长排队和连续失败告警。
- 建立 GitHub run/job 深链接。

### Phase 3：DORA 数据层

- 增加 `ci_delivery_events`、`ci_change_events`、`ci_incidents`。
- 在 CD workflow 完成时写入明确的 environment、deploy_tag、SHA 和结果。
- 关联 PR merge、commit 和生产部署。
- 生成 DORA recording metrics。

### Phase 4：补偿、审计和验收

- 增加 Actions API 的时间窗口补偿任务。
- 验证 webhook 丢失、workflow 重试、取消、回滚和重复事件。
- 用一个完整 UAT snapshot 和一个生产发布样本核对 Dashboard 与 GitHub 页面结果。
- 建立 PostgreSQL 备份、保留和迁移策略。

## 10. 验收标准

### 第一阶段验收

- 新 workflow 在 1 分钟内出现在 exporter 的 PostgreSQL 表中。
- `workflow_run` 和 `workflow_job` 状态、结论、耗时与 GitHub 页面一致。
- 最新 snapshot 能按组织和仓库展示 fan-out 状态。
- 失败率、P50/P95 耗时、queue duration 和 execution minutes 可查询。
- Grafana 可从失败面板跳转到原始 GitHub run/job。

### DORA 验收

- 生产部署只统计显式 environment=prod 的 CD 事件。
- Lead Time 能通过 merge SHA 关联到具体 PR/commit。
- Change Failure Rate 不把普通 CI failure 混入生产变更失败。
- MTTR 明确区分真实事故 MTTR 和 deployment recovery time 近似值。
- 数据重放、Webhook 重复投递和 workflow retry 不造成重复计数。

## 11. 当前待确认事项

1. `open-platform` PostgreSQL 的具体数据库创建和 TLS 连接入口。
2. Grafana 是否在本轮一并启用，还是先把指标写入 VictoriaMetrics。
3. GitHub App 是否已有可复用的 Actions read 权限；若没有，需新增只读 App。
4. 四个组织是否允许组织级 Webhook，还是必须逐仓库配置。
5. 生产部署成功事件由哪个 CD workflow 作为 DORA 的权威来源。
6. 是否已有事故/故障记录来源，用于计算真实 MTTR。
7. 构建分钟数最终采用 execution minutes、billable minutes，还是两者并列展示。

## 12. 结论

第一阶段可以完全基于现有基础设施落地：`promhippie/github_exporter + PostgreSQL + VictoriaMetrics/Prometheus + Grafana`。

DORA 不是 exporter 开箱即用的结果，需要在 CI/CD 事件基础上增加部署环境、deploy tag、PR merge 和事故恢复语义。计划应先完成可验证的流水线状态、失败率、耗时和构建分钟数，再进入 DORA 数据层，避免把 CI 失败误报为生产变更失败。
