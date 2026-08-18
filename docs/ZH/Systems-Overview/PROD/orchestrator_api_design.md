# Orchestrator API Design (后端调度 API 设计)

本文档旨在为底层的 IaC 基础设施自动化和多集群迁移操作提供标准的可编程接口 (Backend API)，将其从 GitHub Actions 界面封装提炼，为 Console 面板（如主控台前端）以及后续的 AI 智能代理 (AI Agents) 提供统一的管控能力。

## 核心设计决策 (Design Decisions)
- **调度解耦**: 后端作为纯粹的 **Orchestrator** (调度器)。在初期阶段，后端可通过调用 GitHub Actions API (`workflow_dispatch`) 作为底层执行引擎。后续亦可切换为自建的 Temporal / Celery 本地执行引擎，而本 API 契约无需变动。
- **配置即声明**: 前端只下发“域 (Domain)”、“动作 (Action)”和“资源配额 (Plan)”等维度参数，所有的复杂依赖解析都在 `iac_modules` 侧由 Jinja2 处理完成。

---

## Proposed Changes: API Specification

### Base URL
`/api/v1/orchestration/site-migration`

### 1. Create a Provisioning / Migration Job
**Endpoint**: `POST /jobs`
**Description**: Initiates a new Infrastructure-as-Code and data synchronization task (maps directly to the workflow inputs).

**Request Body (JSON):**
```json
{
  "cloud_provider": "vultr",         // enum: ["vultr", "aws", "gcp", "aliyun"]
  "target_domains": "ai-workspace",  // enum: ["all", "ai-workspace", "web-saas", "infra-platform"]
  "instance_plan": "2C4G",           // enum: ["4C8G", "2C4G"]
  "toolkit_action": "migrate",       // enum: ["migrate", "backup", "restore"]
  "terraform_action": "apply",       // enum: ["apply", "destroy"]
  "source_host": "install.svc.plus",
  "source_domain_base": "svc.plus",
  "target_domain_base": "onwalk.net",
  "run_provision_and_deploy": true,
  "dns_mode": "none",             // enum: ["none", "uat-records", "prod-cutover"]
  
  // ================= 预留扩展 (Reserved Extensions) =================
  "vault_integration": {
    "role": "github-actions-platform-ops-toolkit",
    "kv_path": "kv/data/CICD"
  },
  "finops": {
    "enable_infracost_estimation": true,   // 运行预估但不立即执行
    "opencost_tags": {                     // 打在云资源上的标签，用于 Opencost 追踪
      "cost_center": "ai-infra",
      "project": "site-migration"
    }
  }
}
```

**Response (201 Created):**
```json
{
  "job_id": "job_8f7d9a1e2c4b",
  "status": "queued",
  "created_at": "2026-07-02T16:45:00Z",
  "links": {
    "status": "/api/v1/orchestration/site-migration/jobs/job_8f7d9a1e2c4b"
  }
}
```

### 2. Query Job Status
**Endpoint**: `GET /jobs/{job_id}`
**Description**: Fetches the current status and execution logs of the triggered job.

**Response (200 OK):**
```json
{
  "job_id": "job_8f7d9a1e2c4b",
  "status": "in_progress",          // enum: ["queued", "in_progress", "completed", "failed", "cancelled"]
  "target_domains": "ai-workspace",
  "current_stage": "deploy_base",   // enum: ["provision", "deploy_base", "data_migration", "switch_dns"]
  "github_run_url": "https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/123456",
  "started_at": "2026-07-02T16:45:05Z",
  "completed_at": null
}
```

### 3. Cancel a Running Job
**Endpoint**: `POST /jobs/{job_id}/cancel`
**Description**: Cancels the executing job (e.g., interrupts the GitHub Actions workflow run).

**Response (202 Accepted):**
```json
{
  "job_id": "job_8f7d9a1e2c4b",
  "status": "cancelling"
}
```

### 4. Estimate Infrastructure Cost (Infracost)
**Endpoint**: `POST /jobs/estimate`
**Description**: Performs a Terraform Plan and runs Infracost to return a cost estimation without actually provisioning resources.

**Response (200 OK):**
```json
{
  "total_monthly_cost": "24.00",
  "currency": "USD",
  "diff_monthly_cost": "+24.00",
  "breakdown": [
    {
      "resource": "vultr_instance.ai_workspace_node",
      "monthly_cost": "24.00"
    }
  ]
}
```

### 5. Get Available Matrix Configurations
**Endpoint**: `GET /configurations`
**Description**: Returns the supported Domains and Instance Plans to dynamically populate the Frontend Console dropdowns.

**Response (200 OK):**
```json
{
  "cloud_providers": [
    { "id": "vultr", "name": "Vultr Cloud" },
    { "id": "aws", "name": "Amazon Web Services" }
  ],
  "domains": [
    { "id": "all", "name": "All-in-One (全站)" },
    { "id": "ai-workspace", "name": "AI Workspace Domain" },
    { "id": "web-saas", "name": "Web SaaS Domain" },
    { "id": "infra-platform", "name": "Infrastructure Platform Domain" }
  ],
  "instance_plans": [
    { "id": "4C8G", "provider_api_id": "vc2-4c-8gb", "cpu": 4, "ram_gb": 8 },
    { "id": "2C4G", "provider_api_id": "vc2-2c-4gb", "cpu": 2, "ram_gb": 4 }
  ],
  "toolkit_actions": ["migrate", "backup", "restore"],
  "terraform_actions": ["apply", "destroy"]
}
```

### 6. MCP Server Integration (Model Context Protocol)
**Endpoint**: `GET /mcp/sse`
**Description**: Exposes the orchestration capabilities natively to AI Agents (like OpenClaw or internal AI tools). This endpoint implements the standard MCP SSE transport.
**Supported MCP Tools**:
- `trigger_migration_job`: Initiates a deployment/migration.
- `get_job_status`: Polls running jobs.
- `estimate_infracost`: Runs cost estimation for FinOps.
- `read_opencost_metrics`: Fetches running cloud cost metrics for deployed domains.
