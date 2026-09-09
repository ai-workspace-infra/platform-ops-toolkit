def lease_ok:
  if $cleanup then
    (.spec.ttl_minutes == 60 or .spec.ttl_minutes == 120) and
    (.spec.nodes.gateway.max_runtime_minutes == 60 or .spec.nodes.gateway.max_runtime_minutes == 120) and
    (.spec.nodes.one.max_runtime_minutes == 60 or .spec.nodes.one.max_runtime_minutes == 120)
  else
    .spec.ttl_minutes == 60 and
    .spec.nodes.gateway.max_runtime_minutes == 60 and
    .spec.nodes.one.max_runtime_minutes == 60 and
    .spec.node_observation == {mode:"until-expiry",release_on_failure:true}
  end;

.kind == "XConnectLabTopology" and
.metadata.environment == "uat" and
.spec.iac_module == "vpn-overlay/xconnect-lab" and
.spec.environment_reuse == "uat-control-plane-vault-account-and-network" and
.spec.gateway_provider == "aws-spot" and
.spec.compute_policy == "all-cloud-compute-is-aws-spot-by-default" and
lease_ok and
.spec.zero.accounts_api_url == "https://accounts-uat.onwalk.net" and
.spec.zero.portal_url == "https://console-cloudflare-uat.onwalk.net/panel/xconnect-zero" and
.spec.zero.source_of_truth == "formal-accounts-api-and-portal" and
.spec.zero.lab_controller.is_formal_config_source == false and
.spec.nodes.gateway.product == "XConnect One Gateway" and
.spec.nodes.gateway.role == "relay" and
.spec.nodes.gateway.service_role == "relay/service" and
.spec.nodes.gateway.baseline == "independent-linux-node-external-wireguard-xray" and
.spec.nodes.gateway.architecture == "arm64" and
.spec.nodes.gateway.instance_type == "t4g.small" and
.spec.nodes.gateway.vcpu == 2 and
.spec.nodes.gateway.memory_gib == 2 and
.spec.nodes.gateway.purchase_model == "spot" and
.spec.nodes.one.product == "XConnect One Linux client CLI" and
.spec.nodes.one.role == "controlled-client" and
.spec.nodes.one.baseline == "independent-linux-node-managed-xray-wireguard" and
.spec.nodes.one.architecture == "arm64" and
.spec.nodes.one.instance_type == "t4g.micro" and
.spec.nodes.one.vcpu == 2 and
.spec.nodes.one.memory_gib == 1 and
.spec.nodes.one.purchase_model == "spot" and
.spec.aws.reuse_default_vpc == true and
.spec.aws.reuse_default_subnet == true and
(.spec.aws.ami_ssm_parameter | contains("/arm64/")) and
.spec.vault.address == "https://vault.svc.plus" and
.spec.vault.role == "github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab" and
.spec.vault.infrastructure_path == "kv/data/CICD/uat" and
.spec.vault.runtime_path == "kv/data/uat/xconnect-one" and
.spec.vault.github_app_path == "kv/data/CICD/github-app/daily-snapshot" and
.spec.overlay.transport == "vless-tls-xudp" and
.spec.overlay.gateway_address == "10.77.0.1/32" and
.spec.overlay.device_address == "10.77.0.2/32" and
.spec.overlay.public_wireguard_ingress == false and
.spec.gateway_transport.enabled == true and
.spec.gateway_transport.exposure == "public-restricted" and
.spec.gateway_transport.transport == "vless-tls-xudp" and
.spec.gateway_transport.port == 443 and
.spec.gateway_transport.ingress_cidrs == [] and
.spec.gateway_transport.public_wireguard_ingress == false and
.spec.gateway_transport.allowlist_source == "workflow-dispatch-runtime-only" and
.spec.observability.enabled == true and
.spec.observability.endpoint == "https://observability.svc.plus" and
.spec.observability.metrics_query_path == "/vmetrics/api/v1/query" and
.spec.observability.environment == "uat" and
.spec.observability.collection == ["node_exporter", "process_exporter", "xconnect_textfile_metrics", "vector_remote_write"] and
.spec.observability.metric_prefix == "xconnect_" and
.spec.observability.credential_source == "vault:kv/data/CICD/observability" and
(.spec.overlay.private_checks | index("ping")) != null and
(.spec.overlay.private_checks | index("http")) != null and
(.spec.overlay.private_checks | index("wireguard-handshake")) != null and
(.spec.overlay.private_checks | index("config-sync")) != null
