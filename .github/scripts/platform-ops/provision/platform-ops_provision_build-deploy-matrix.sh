#!/bin/bash
set -euo pipefail

# A provider CMDB can contain platform facts in addition to SSH host records.
# For example, the GCP open-platform adapter emits project_id, Cloud Run URIs,
# and vault_nodes. Those values are deliberately not deployable hosts. Only a
# flat entry with an IP address may enter the SSH/Ansible matrix; otherwise a
# metadata string would reach setup-deployment-runner and jq would fail with
# "Cannot index string with string \"ip\"".
host_keys() {
  jq -c '[to_entries[]
    | select((.value | type) == "object")
    | select((.value.ip | type) == "string" and (.value.ip | length) > 0)
    | .key]' cmdb.json
}

group_keys() {
  local group="$1"
  jq -c --arg group "${group}" '[to_entries[]
    | select((.value | type) == "object")
    | select((.value.ip | type) == "string" and (.value.ip | length) > 0)
    | select((.value.groups // []) | index($group))
    | .key]' cmdb.json
}

hosts_json="$(host_keys)"
echo "hosts=${hosts_json}" >> "$GITHUB_OUTPUT"
echo "hosts_web_saas=$(group_keys web_saas)" >> "$GITHUB_OUTPUT"
echo "hosts_ai_workspace=$(group_keys ai_workspace)" >> "$GITHUB_OUTPUT"
echo "hosts_infra_platform=$(group_keys infra_platform)" >> "$GITHUB_OUTPUT"
echo "hosts_agent_proxy=$(group_keys agent_proxy)" >> "$GITHUB_OUTPUT"
# Keep the original output for existing consumers, while exposing the IaC
# portion under an explicit name for the hybrid Agent Proxy deployment.
echo "hosts_agent_proxy_iac=$(group_keys agent_proxy)" >> "$GITHUB_OUTPUT"
echo "count=$(jq 'length' <<<"${hosts_json}")" >> "$GITHUB_OUTPUT"
