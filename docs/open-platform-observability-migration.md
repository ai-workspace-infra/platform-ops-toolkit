# Open Platform Observability migration plan

This runbook stages `observability.svc.plus` on the UAT Akamai `open-platform`
node while keeping the current `46.250.251.132` host as the live source and
rollback point. Provisioning and service installation are safe to run before
cutover. Do not change DNS or stop the source as part of that deployment run.

## Source inventory captured for this migration

The source uses Docker Compose under `/opt/observability-server`. Its Grafana
database is in the named volume `observability-server_grafana_data`; the mounted
JSON dashboard directory is `/opt/observability-server/grafana/dashboards`.
The Grafana database file was approximately 24 MB and the named volume 281 MB.
The database `dashboard` table had zero rows during inventory, so all 11 active
dashboards are file-provisioned from the JSON assets in the Playbooks repository
(`roles/docker/observability-server/files/`). The Ansible role now discovers
and copies every Git-managed `*.json` file from that directory; no Grafana
SQLite dashboard restore is needed for the current inventory. Keep the JSON
UID/title comparison as a deployment acceptance gate. Two host-side
`.json.*.bak` files are not loaded and are not part of the Git inventory.

Three live files differ from the checked-in canonical files: the live Node
Exporter and Xray dashboards lack repository tags, and the live Process
Exporter dashboard has older datasource UIDs. Deploy the Playbooks `main`
versions as-is; do not import those drifted live copies into Git.

Observed store sizes at preflight were approximately 3.6 GB for VictoriaMetrics,
1.2 GB for VictoriaLogs, 67 MB for VictoriaTraces, and 650 MB for Prometheus.
Sizes change while ingestion continues; remeasure immediately before transfer
and check that the target has sufficient free space. The selected Akamai 2C4G
plan maps to `g6-standard-2` (4 GB RAM, 2 vCPUs, 80 GB disk).

## Staged migration

1. **Deploy the target without traffic changes.** Use the standalone Observability
   workflow with `deployment_action=deploy`, `instance_plan=2C4G`, and an
   immutable `deploy_tag`. It dispatches Selfhost Orchestrator with
   `target_domains=open-platform`, `open_platform_service=observability`, and
   `dns_mode=none`. The service selector keeps Vault and IAM out of the install.
   The workflow resolves the new node from the child run's CMDB artifact and
   verifies Grafana, the four service containers, HTTPS host routing, and an
   exact SHA-256 match for every Playbooks dashboard JSON. Keep the old source
   serving production ingestion and queries.

2. **Record a recoverable baseline.** Keep the old source volumes intact as the
   rollback copy, and record checksums, timestamps, component image versions,
   and the dashboard UID/title list from both the Playbooks JSON assets and
   running Grafana API. The migration jobs create application-consistent store
   snapshots and retain the target's pre-migration files; they do not create an
   off-host encrypted backup. If policy requires one, take it to the approved
   backup location before cutover. Keep credentials and dashboard payloads out
   of workflow logs. Grafana SQLite may be backed up with SQLite's online
   backup API for other Grafana metadata, but it is not the source of the
   currently provisioned dashboard definitions. A raw live copy of `grafana.db`
   is not a consistent backup.

3. **Bulk-copy telemetry while the source remains live.** Dispatch with
   `deployment_action=skip`, set `target_ip_override` to the existing target,
   choose `migration_mode=baseline`, and select `data_components=all` (or one
   store for a controlled retry). The workflow fans out a matrix over
   VictoriaMetrics, VictoriaLogs, and VictoriaTraces. VictoriaMetrics uses the
   version-matched `vmbackup` snapshot/backup image; Logs and Traces create
   consistent snapshots per day partition and copy those snapshots. Each
   matrix job restores into the matching target Docker volume, checks component
   readiness, image-version compatibility, target free space, and non-empty
   data, and retains the target's pre-migration files
   under `/var/lib/observability-migration-backups/<run-id>/`. The old source
   volumes are never modified. Prometheus is a scrape configuration mounted by
   VictoriaMetrics, not a separate historical-data store in this deployment.

4. **Restore and compare on the target.** The pipeline stops target stateful
   containers, saves their current data under the migration-backup directory,
   and restores the source stores using the same component image versions.
   Verify health, time ranges, series/partition counts, and representative
   historical queries. Deploy all Git-managed
   provisioning JSON, then compare dashboard UID/title lists and open
   representative panels. If a future inventory finds dashboard rows in
   Grafana SQLite, export and add those dashboards to the Playbooks repository
   before cutover. Do not mark migration ready if any dashboard, folder,
   datasource, alert, or historical query is missing.

5. **Run the final sync and optional DNS cutover.** Start a separate workflow run
   with `deployment_action=skip`, the target IP override, `migration_mode=final`,
   `data_components=all`, and `confirm_source_writers_paused=true`. The boolean
   is an operator attestation: pause all external writers to the old source
   before dispatch. After each store's final snapshot is restored, the matrix
   verification jobs check store bytes, partition counts, component readiness,
   Grafana health, dashboard file checksums, and HTTPS host routing. Leave
   `dns_action=none` to finish and review the target separately. To switch,
   choose `dns_action=cutover`, set `confirm_dns_change=true`, and set
   `confirm_target_historical_queries=true` only after comparing representative
   metrics, logs, and traces queries on the baseline-restored target with the
   source. The GitHub `uat` environment can add required reviewers.
   The DNS job changes only the `observability.svc.plus` A record, and refuses
   to proceed unless its current value still matches `source_ip`. It preserves
   TTL/proxy settings, verifies Cloudflare's record and public DNS response,
   and automatically restores the previous value if DNS propagation
   verification fails. `dns_action=rollback` is available with
   `deployment_action=skip`; when supplied, `target_ip_override` is also used
   as the expected current value before restoring the source IP.

6. **Rollback and observation.** If a gate fails, restore the recorded DNS value
   to the source, verify source ingestion and dashboard access, and retain both
   copies for investigation. After cutover, monitor target ingestion and query
   health through the agreed observation window. Source retirement is a separate
   approved change and is never part of this workflow.

## Workflow controls and boundaries

| Input | Choices / default | Effect |
| --- | --- | --- |
| `deployment_action` | `plan` (default), `infra`, `deploy`, `skip` | Validate, provision only, deploy the service, or skip deployment for a later sync/cutover run. |
| `instance_plan` | `2C4G` (default), `4C8G` | Akamai size used when deployment runs. |
| `mcp_services` | `none` (default), `all`, or comma-separated service names | Optional MCP adapters (`grafana`, `victoriametrics`, `victorialogs`, `victoriatraces`). Each selected adapter is deployed and verified against its matching core backend; Grafana and Victoria core services remain enabled independently. |
| `deploy_tag` | empty | Required immutable UAT daily-build tag when `deployment_action=deploy`. |
| `source_ref` | `main` | Reviewed ref used for toolkit, Playbooks, and child workflow inputs. |
| `migration_mode` | `none` (default), `baseline`, `final` | Select no copy, live baseline snapshot, or final snapshot after source writers are paused. |
| `data_components` | `all` (default), `metrics`, `logs`, `traces` | Selects one or all matrix components. DNS cutover requires `all`. |
| `dns_action` | `none` (default), `cutover`, `rollback` | No DNS write by default; cutover and rollback affect only the Observability A record. |
| `source_ip` | `46.250.251.132` | SSH source and expected current DNS value for cutover. |
| `target_ip_override` | empty | Existing target IP required for migration runs that skip provisioning. |
| `confirm_source_writers_paused` | `false` | Required for `migration_mode=final`; operator must pause writers first. |
| `confirm_target_historical_queries` | `false` | Required for DNS cutover; attest that representative history queries matched after baseline restore. |
| `confirm_dns_change` | `false` | Required for either DNS action. |

The parent workflow is split into target deployment, target IP resolution,
per-store migration matrix, per-store verification matrix, dashboard/service
verification, and DNS jobs. Dependencies prevent verification or cutover from
running until the preceding stage succeeds. The historical-query attestation
is based on a manual target/source comparison after the baseline run. A source
pause cannot be inferred by the pipeline; the final-sync confirmation remains
an operator attestation.
The known source Grafana DB had zero dashboard rows, so panels are sourced from
Git and compared by checksum. Dashboard rows saved only in SQLite would require
export to Git before they can be treated as durable provisioning assets.

## Primary references

- [Playbooks Grafana dashboard source of truth](https://github.com/ai-workspace-infra/playbooks/blob/main/docs/observability-grafana-dashboards.md)
- [VictoriaMetrics backup and restore](https://docs.victoriametrics.com/vmbackup/)
- [VictoriaLogs backup and restore](https://docs.victoriametrics.com/victorialogs/)
- [VictoriaTraces backup and restore](https://docs.victoriametrics.com/victoriatraces/)
- [VictoriaMetrics snapshot and restore](https://docs.victoriametrics.com/victoriametrics/#how-to-work-with-snapshots)
