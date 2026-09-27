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
   workflow with `operation=deploy`, `instance_plan=2C4G`,
   `target_domains=open-platform`, `open_platform_service=observability`, and
   `dns_mode=none`. Confirm the target node, Grafana, Caddy TLS/host routing,
   provisioned dashboards, datasources, and disk capacity. Keep the old source
   serving all production ingestion and queries.

2. **Take a recoverable baseline.** Create application-consistent backups for
   each Victoria store. Save an immutable encrypted backup location, checksums,
   timestamps, component image versions, and the dashboard UID/title list from
   both the Playbooks JSON assets and the running Grafana API. Keep credentials
   and dashboard payloads out of workflow logs. Grafana SQLite may be backed up
   with SQLite's online backup API for other Grafana metadata, but it is not the
   source of the currently provisioned dashboard definitions. A raw live copy
   of `grafana.db` is not a consistent backup.

3. **Bulk-copy telemetry while the source remains live.** Copy the baseline to
   target staging paths; do not let the target services ingest into these paths
   while they are being written. Use VictoriaMetrics instant snapshots and its
   supported backup/restore tooling. For VictoriaLogs and VictoriaTraces, use
   their per-day partition snapshot procedures and repeated `rsync` passes; the
   final pass must run after the changed partitions are detached or the source
   writers are stopped. For Prometheus, use its supported snapshot procedure or
   a cleanly stopped copy. Keep the source volumes untouched.

4. **Restore and compare on the target.** Stop target stateful containers before
   replacing their empty data paths. Restore the stores using compatible image
   versions, start them, and compare health, time ranges, series/partition
   counts, and representative historical queries. Deploy all Git-managed
   provisioning JSON, then compare dashboard UID/title lists and open
   representative panels. If a future inventory finds dashboard rows in
   Grafana SQLite, export and add those dashboards to the Playbooks repository
   before cutover. Do not mark migration ready if any dashboard, folder,
   datasource, alert, or historical query is missing.

5. **Schedule a separate final-sync and cutover run.** Require an operator
   approval and a maintenance window. Record the current DNS answer and TTL,
   pause or drain telemetry writers, make the final consistent sync of changed
   data, start target services, and rerun the target health/query/dashboard
   checks. Then update only `observability.svc.plus` to the target IP. Verify
   public TLS, dashboard access, metrics/logs/traces ingestion, and historical
   queries. Leave the source intact and available for rollback.

6. **Rollback and observation.** If a gate fails, restore the recorded DNS value
   to the source, verify source ingestion and dashboard access, and retain both
   copies for investigation. After cutover, monitor target ingestion and query
   health through the agreed observation window. Source retirement is a separate
   approved change and is never part of this workflow.

## Current workflow boundary

The standalone workflow currently performs the first stage only. Historical
store synchronization and DNS changes are deliberately separate follow-up stages
because they need application-consistent snapshots, version checks, an explicit
write-pause plan, and operator approval. Merely reinstalling Grafana would keep
the Git-provisioned JSON dashboards but would not preserve dashboards saved only
in Grafana's SQLite database.

## Primary references

- [Playbooks Grafana dashboard source of truth](https://github.com/ai-workspace-infra/playbooks/blob/main/docs/observability-grafana-dashboards.md)
- [VictoriaMetrics backup and restore](https://docs.victoriametrics.com/vmbackup/)
- [VictoriaLogs backup and restore](https://docs.victoriametrics.com/victorialogs/)
- [VictoriaTraces backup and restore](https://docs.victoriametrics.com/victoriatraces/)
