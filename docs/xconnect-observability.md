# XConnect Gateway and One observability

Every deployed Linux Gateway and One receives the same base collector:

```text
xconnect-node-exporter + XConnect textfile collector
  -> Vector remote write
  -> https://observability.svc.plus
  -> VictoriaMetrics datasource in Grafana
```

The deployment workflow reads the Vector basic-auth credential only from
`kv/data/CICD/observability`. GitOps declares the UAT endpoint, environment,
metric prefix and collection contract; it contains no secret.

The collector publishes these UAT metrics:

- `xconnect_runtime_info`
- `xconnect_runtime_up{component="wireguard|xray|state"}`
- `xconnect_wireguard_peer_count`
- `xconnect_wireguard_latest_handshake_age_seconds`

All include stable `role`, `environment`, and `instance` labels. For the
external TW Gateway the instance is `gw-uat-tw-xconnect`; each disposable One
uses its run-bound device ID.

The cloud workflow accepts deployment only after each node has a local
textfile metric, `xconnect-node-exporter` listening locally on `127.0.0.1:19100`,
`vector`, and the collector timer active, and the central VictoriaMetrics query
endpoint returns one `xconnect_runtime_info` series for both Gateway and One.
Grafana reads the same datasource, so no separate Grafana-side agent
registration is required. This deployment deliberately does not change the
Gateway host baseline, firewall, hostname or SSH configuration.
