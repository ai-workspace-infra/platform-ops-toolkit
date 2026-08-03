# UAT destroy/redeploy routing fix — 2026-08-03

## Scope

This change is limited to the UAT `web-saas + agent-proxy` delivery path. It
does not change production hosts, production DNS, or the upstream Xray
Exporter repository.

The intended UAT flow is:

```text
Xray -> ai-workspace-xstream/xray-exporter -> Vector -> Billing -> PostgreSQL
     -> Accounts -> Portal
```

## Evidence from the failed delivery

- The native agent deployment received `XRAY_EXPORTER_RELEASE_REPOSITORY=compassvpn/xray-exporter`
  together with the UAT snapshot tag `uat-daily-build-2026.08.03-r6`.
- That tag exists on the fork used for the UAT build, not on the upstream
  compatibility repository. The Exporter download therefore returned 404.
- The UAT DNS reconciler rendered only `billing-*`, `console-*`, and
  `accounts-*` records from the Web SaaS IP. It did not render the separate
  `agent-proxy.<target-domain>` record from the agent-proxy CMDB IP. This left
  `agent-proxy.onwalk.net` resolving to the Console host.
- On the affected agent host, the service units had the new `--node-id` and
  snapshot flags while the installed binary was an older v0.6.0 build that did
  not support them. Both exporter units consequently crash-looped, Vector had
  no scrape endpoint, and Billing/PostgreSQL received no usage snapshots.

## Fix

1. Leave the two Exporter inputs blank by default. For UAT, derive the release
   repository from `ai-workspace-xstream/xray-exporter` and the version from
   the resolved `deploy_tag`. Production retains the upstream
   `compassvpn/xray-exporter` / `v0.6.0` compatibility default.
2. Extend the parameterized UAT DNS reconciler to render
   `agent-proxy.<target-domain>` to the single `agent_proxy` CMDB host IP. The
   existing three Web SaaS records continue to use the Web SaaS host IP.
3. Keep DNS changes UAT-only, idempotent, non-proxied, and parameterized; no
   IP address is hard-coded.

## Destructive UAT validation sequence

After this change is merged, the UAT-only workflow will be run in two phases:

1. `action=destroy`, `target_domains="web-saas + agent-proxy"`,
   `vault_env_path=uat`, `cloud_provider=vultr-vps`. This destroys only the
   dedicated `web-saas-agent-proxy` Terraform state and its two UAT VPSs.
2. `action=deploy` with the same target, `instance_plan=2C4G`, the GitOps-pinned
   UAT snapshot tag, and application deployment enabled. The agent-proxy host
   remains the matrix-defined 1C2G host.

`confirm_dns_switch` remains false. The final gate will verify the direct UAT
  IPs and then the public records/paths:

- Exporter binary and flags, both exporter services, and `/scrape`;
- Vector scrape acceptance and Billing sink delivery;
- Billing ingest, PostgreSQL `traffic_minute_buckets`/`billing_ledger`/quota
  rows;
- Accounts usage summary and `/panel/account` non-zero presentation;
- Grafana Xray series for `agent-proxy.onwalk.net`.

Production comparison nodes remain read-only throughout this exercise.
