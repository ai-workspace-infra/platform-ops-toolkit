#!/bin/bash
set -euo pipefail

host_filter='true'
if [[ "${DEPLOYMENT_ENV:-}" == 'uat' && "${TARGET_DOMAINS:-}" == *agent-proxy* ]]; then
  # HK ap-east-1 currently reaches TCP/22 but does not provide an SSH banner
  # after replacement. Keep its short-lived infrastructure declaration for
  # later recovery, but do not let one unavailable regional node block the
  # UAT JP/US Agent Proxy deployment or its Caddy/Xray traffic.
  host_filter='((.value.tags // []) | index("hk") | not)'
  echo '::notice::UAT HK Agent Proxy is optional for this run; excluding hk-tagged hosts from bootstrap, service deployment, and probes.' >&2
fi

jq_hosts() {
  local selection="$1"
  jq -c "[to_entries | sort_by(.key)[] | select(${host_filter}) | ${selection}]" cmdb.json
}

echo "hosts=$(jq_hosts '.key')" >> "$GITHUB_OUTPUT"
echo "hosts_web_saas=$(jq_hosts 'select(.value.groups // [] | contains(["web_saas"])) | .key')" >> "$GITHUB_OUTPUT"
echo "hosts_ai_workspace=$(jq_hosts 'select(.value.groups // [] | contains(["ai_workspace"])) | .key')" >> "$GITHUB_OUTPUT"
echo "hosts_infra_platform=$(jq_hosts 'select(.value.groups // [] | contains(["infra_platform"])) | .key')" >> "$GITHUB_OUTPUT"
echo "hosts_agent_proxy=$(jq_hosts 'select(.value.groups // [] | contains(["agent_proxy"])) | .key')" >> "$GITHUB_OUTPUT"
# Keep the original output for existing consumers, while exposing the IaC
# portion under an explicit name for the hybrid Agent Proxy deployment.
echo "hosts_agent_proxy_iac=$(jq_hosts 'select(.value.groups // [] | contains(["agent_proxy"])) | .key')" >> "$GITHUB_OUTPUT"
echo "count=$(jq_hosts '.' | jq 'length')" >> "$GITHUB_OUTPUT"
