# Supabase PostgreSQL → Observability

This runbook connects the two Supabase projects shown in the organization dashboard to `observability.svc.plus` without placing a database password in Git:

| Grafana instance | Supabase project | Region |
| --- | --- | --- |
| `supabase-xworktech` | `xworktech` | AWS `ap-northeast-1` |
| `supabase-xworktech-prod` | `xworktech-prod` | AWS `ap-southeast-1` |

The Observability host runs one `postgres_exporter` container per project. VictoriaMetrics scrapes them internally every 15 seconds, so the existing **PostgreSQL Database Overview** dashboard can select either instance.

## 1. Obtain least-privilege connection strings

In each Supabase project, open **Connect** and copy the **Session pooler** connection string (port `5432`). This is the appropriate persistent-client option when the Observability host is IPv4-only. Prefer the direct connection only when that host has IPv6 connectivity or the project has the IPv4 add-on.

Create a dedicated monitoring role in each project and grant it `pg_monitor`; use that role in the connection string. Do not use a browser/API key, service-role key, or a production application password.

If Database network restrictions are enabled, allow the public egress IP of `observability.svc.plus` in both Supabase projects.

## 2. Store the two DSNs outside Git

Put these values in an Ansible-Vault encrypted inventory or an external inventory backed by Vault. The names and labels below are safe to commit; only `data_source_name` is secret.

```yaml
observability_postgres_exporters:
  - name: xworktech
    instance: supabase-xworktech
    environment: production
    region: ap-northeast-1
    data_source_name: "postgresql://<monitor-user>:<password>@aws-<region>.pooler.supabase.com:5432/postgres?sslmode=require"
  - name: xworktech-prod
    instance: supabase-xworktech-prod
    environment: production
    region: ap-southeast-1
    data_source_name: "postgresql://<monitor-user>:<password>@aws-<region>.pooler.supabase.com:5432/postgres?sslmode=require"
```

The actual pooler hostname and username include the project reference. Copy them from each project's **Connect** dialog rather than deriving them from its display name.

## 3. Deploy and verify

```bash
cd /Users/shenlan/workspaces/ai-workspace-infra/playbooks
ansible-playbook -i inventory.ini deploy_observability.yml \
  -e @<vault-backed-observability-vars.yml>
```

On the Observability host, verify both exporters and their target health:

```bash
docker ps --format '{{.Names}}' | grep xstream_postgres_exporter
curl -fsS http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=pg_up{job="postgres-exporter"}'
```

Then open the PostgreSQL dashboard and choose `supabase-xworktech` or `supabase-xworktech-prod` in **Instance**. A healthy integration returns `pg_up == 1` and per-database `pg_stat_database_*` series.

## Failure triage

- `pg_up = 0` with a DNS/network error: use the Session pooler endpoint and allow the Observability egress IP in Supabase Database network restrictions.
- Authentication failure: ensure the pooler username includes the project reference and update only the Vault-backed DSN.
- Permission failure: grant the dedicated monitoring role `pg_monitor`; keep the exporter read-only.
- Dashboard has no values while `pg_up = 1`: check `pg_stat_database_*` in Grafana Explore with `job="postgres-exporter"`; the selected dashboard must query the same VictoriaMetrics datasource.
