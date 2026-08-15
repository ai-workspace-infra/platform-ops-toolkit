#!/bin/bash
set -euo pipefail

echo "hosts=$(jq -c 'keys' cmdb.json)" >> "$GITHUB_OUTPUT"
echo "hosts_web_saas=$(jq -c '[to_entries[] | select(.value.groups // [] | contains(["web_saas"])) | .key]' cmdb.json)" >> "$GITHUB_OUTPUT"
echo "hosts_ai_workspace=$(jq -c '[to_entries[] | select(.value.groups // [] | contains(["ai_workspace"])) | .key]' cmdb.json)" >> "$GITHUB_OUTPUT"
echo "hosts_infra_platform=$(jq -c '[to_entries[] | select(.value.groups // [] | contains(["infra_platform"])) | .key]' cmdb.json)" >> "$GITHUB_OUTPUT"
echo "hosts_agent_proxy=$(jq -c '[to_entries[] | select(.value.groups // [] | contains(["agent_proxy"])) | .key]' cmdb.json)" >> "$GITHUB_OUTPUT"
echo "count=$(jq 'length' cmdb.json)" >> "$GITHUB_OUTPUT"
