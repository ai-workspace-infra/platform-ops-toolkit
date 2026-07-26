# Platform Operations Toolkit (SVC.plus) - 项目规划与进度

## 1. 项目定位与目标

**项目名称**: SVC.plus Platform Operations Toolkit  
**定位**: Cloud Neutral Environment Lifecycle Management Platform  
**目标**: 将现有 `platform-ops-toolkit` 升级为面向云中立平台的环境生命周期管理工具。不仅负责迁移，还统一管理：多环境管理、应用部署、数据迁移、配置同步、备份与恢复、灾难恢复、发布回滚、基础设施变更操作。

**核心理念**: Environment Lifecycle as Code  
通过 CLI、API、MCP 三种方式，让开发者、平台工程师和 AI Agent 可以安全操作基础设施。

**未来产品矩阵**:
```text
ai-workspace-infra/
├── platform-ops-toolkit       (Environment & Lifecycle Management)
├── environment-control-plane  
├── observability-stack        
├── finops-toolkit             
└── cloud-neutral-playbooks    
```
*(形成融合 AI Workspace, Open Platform, Platform Operations, Observability, FinOps 的 Cloud Neutral Platform。MCP 层的加入将使项目从传统 DevOps 升级为 AI Native Platform Engineering 工具)*

---

## 2. 目标架构与功能模块

### 目标架构
```text
                 Human
                   |
        ------------------------
        |                      |
       CLI                    MCP
        |                      |
        -------- API Layer -----
                   |
        Platform Operations Engine
                   |
    --------------------------------
    |              |               |
 Migration      Backup        Deployment
    |              |               |
 Database       Storage       Runtime
 Config         Snapshot      Rollback
 Infrastructure Recovery      Release
```

### 核心功能模块
1. **Environment Management**: 创建环境、环境复制、环境同步、状态检查、差异比较。
2. **Migration Engine**: 站点迁移 (Site)、数据库 (Database)、存储 (Storage)、配置 (Configuration)、跨区域迁移 (Cross-region)。
3. **Backup & Recovery**: 定时备份、手动快照、增量备份、恢复验证、Disaster Recovery。
4. **Deployment Engine**: 应用部署、版本发布、蓝绿发布 (Blue/Green)、金丝雀发布 (Canary)、Release 管理。
5. **Rollback System**: 应用回滚、数据库回滚、配置回滚、基础设施回滚。

---

## 3. 接口设计与安全控制

### CLI (`platctl`)
- 目标：人类友好、自动生成日志、支持 JSON 输出、CI/CD 集成、支持 GitHub Actions。
- 技术：Go Cobra。

### API (REST / gRPC)
- 统一 REST API（如 `/api/v1/environments`、`/deployments`、`/migrations` 等）。
- 要求：OAuth2/OIDC 身份认证、RBAC 权限控制、Audit Log、Operation History、Dry Run、Approval Workflow。

### MCP Server (AI-Native Enablement)
- 目标：让 Claude Code、Codex、XWorkmate、OpenClaw 等 Agent 可以通过 MCP 调用平台能力。
- **安全隔离**：AI Agent 不直接访问服务器，所有操作必须经过：`Agent -> MCP Server -> API Gateway -> Policy Engine -> Operation Engine`。
- 支持：权限验证、操作审批、风险评估、命令审计、Secret 隔离。

---

## 4. 实施阶段规划 (Phases) & 当前进度

### ✅ Phase 1: Project Scaffolding & CLI Foundation (已完成)
- [x] Initialize `platform-ops-toolkit` Go module.
- [x] Setup Go project layout (`cmd/platctl/`, `pkg/`, `internal/`).
- [x] Implement the Cobra CLI foundation (`platctl env`, `platctl deploy`, `platctl migrate`, `platctl backup`, `platctl restore`, `platctl rollback`).

### ⏳ Phase 2: Core Operations Engine & Integrations (规划中)
- [ ] 定义核心功能接口 (Environment, Migration, Backup, Deployment, Rollback)。
- [ ] 封装底层执行逻辑，集成 Terraform/OpenTofu, Ansible, Kubernetes。
- [ ] 集成 Vault（OIDC / JWT），实现 Secret 动态获取。
- [ ] 将现有 `platform-ops-toolkit` 的逻辑平滑迁移至新引擎。

### ⏳ Phase 3: API Layer & Security (规划中)
- [ ] 搭建 REST/gRPC API 服务（如基于 Gin 或 gRPC）。
- [ ] 实现 OAuth2/OIDC 用户鉴权与 RBAC。
- [ ] 落地 Policy Engine，实现操作审批与 Audit Logging。

### ⏳ Phase 4: MCP Server Integration (规划中)
- [ ] 构建 MCP Server，暴露 `environment.list`, `deployment.create`, `migration.plan` 等工具给 AI Agent。
- [ ] 实现 Agent 操作与 Policy Engine 的安全拦截对接。

---

## 5. 当前推进中的交付线索

### ⏳ 交付线索 A：CI 子代理调试 + 四域 compose 补全 + UAT 端到端

这条线正在独立推进，目标是把“逐仓 CI 调试”、“`gitops` 四域结构差异整理”和
“IaC → Doco-CD → DNS”串成一条可重复执行的交付链。

- 任务入口: [2026-07-26-ci-debugging-subagents-compose-and-uat-end-to-end.md](2026-07-26-ci-debugging-subagents-compose-and-uat-end-to-end.md)
- 当前优先仓库: `accounts`、`portal`
- 当前优先对齐项: `gitops` 里的数据库与 stunnel 结构、UAT 交付链验证

### 这条线的阶段目标

- 先把 5 个仓库的 CI 结论统一成可复用的诊断格式
- 再补齐四个业务域的部署差异表
- 最后验证 UAT 主机上的 Doco-CD 收敛和 DNS 发布
