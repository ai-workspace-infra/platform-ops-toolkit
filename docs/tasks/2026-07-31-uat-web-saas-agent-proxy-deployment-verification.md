# UAT Web SaaS + Agent Proxy：完整快照部署验证交接

## 目标

验证 `web-saas + agent-proxy` 在 UAT 环境使用明确版本
`daily-build-2026.07.30` 的整套部署：基础设施、主机 bootstrap、域级交付、
DNS 切换与最终可观测性均须成功。

## 当前运行

- Workflow: `Deploy Environment & Provision Infrastructure`
- Run: <https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30600776586>
- Trigger: `workflow_dispatch` on `main`
- Environment: `uat`
- Target domains: `web-saas + agent-proxy`
- `deploy_ref`: `daily-build-2026.07.30`
- `deploy_tag`: `daily-build-2026.07.30`
- `run_full_stack`: `true`
- `cloud_provider`: `vultr-vps`
- DNS confirmation: `true`

`deploy_tag` is the version consumed by CD; `deploy_ref` is only a checkout
reference. Never substitute an empty value, `main`, or `latest` for it.

## Progress (2026-07-31)

Completed successfully:

1. Route profile and OIDC/Vault credential loading.
2. Terraform render, init, apply, inventory generation, deployment matrix, and
   environment credential initialization.
3. GitOps update for the `web-saas` image tags.
4. SSH connectivity and Ansible installation on both provisioned hosts:
   `console-uat.onwalk.net` and `agent-proxy.onwalk.net`.

In progress:

- Bootstrap roles on both hosts, followed by TLS restoration.

Pending after bootstrap:

1. `web-saas` domain CD and service observation.
2. Native `agent-proxy` deployment and service verification.
3. DNS cutover and final observation.

## Snapshot-completeness gate

The daily snapshot run
<https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/30566013855>
reported successful builds for `accounts`, `billing-service`, `docs`, `portal`,
and `postgresql.svc.plus`. It did **not** verify a Console release nor the
agent-proxy source/build chain as part of that build matrix.

Do not treat a green workflow alone as proof of a complete cross-domain
snapshot. Before accepting this deployment, the final verifier must confirm:

- web-saas uses `daily-build-2026.07.30` for Accounts, Billing, and Console;
- PostgreSQL, Caddy, and stunnel remain pinned to explicit immutable versions;
- agent-proxy services (Caddy, `agent-svc-plus`, Xray, and exporters) are
  active on the same requested source/version boundary;
- final web-saas observation and DNS cutover jobs succeed.

## Recovery / continuation

If the current run fails, inspect the first failed job log before re-running.
Do not launch another full-stack run concurrently: the workflow concurrency
group is shared and this run has already applied infrastructure and updated
GitOps. Re-run with the same explicit `deploy_tag` only after identifying the
failed stage.
