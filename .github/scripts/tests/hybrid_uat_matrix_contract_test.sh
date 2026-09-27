#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
matrix="${repo_root}/.github/hybrid/uat-resource-matrix.json"
dispatcher="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_dispatch-hybrid-uat-matrix.sh"
workflow="${repo_root}/.github/workflows/hybrid-orchestrator.yml"

jq -e '
  .environment == "uat" and .target_domains == "all" and
  ([.resources[].order] == [1,2,3,4,5,6,7,8]) and
  ([.resources[] | select(.management_mode == "terraform") | .namespace] ==
    ["open-platform","ai-workspace","agent-proxy-jp","agent-proxy-us","agent-proxy-sg"]) and
  ([.resources[] | select(.management_mode == "existing") | .namespace] ==
    ["agent-proxy-tw","agent-proxy-ph"]) and
  ([.resources[] | select(.management_mode == "existing+serverless") | .namespace] == ["web-saas"]) and
  ([.resources[] | select(.management_mode == "terraform") | .provider] ==
    ["akamai-cloud","gcp-cloud","aws-cloud","gcp-cloud","akamai-cloud"]) and
  ([.resources[] | select(.management_mode == "terraform") | .region] ==
    ["us-east","asia-east1","ap-northeast-1","us-central1","sg-sin-2"]) and
  ([.resources[] | select(.management_mode == "existing") | .provider] | unique) == ["ulighthost"] and
  ([.resources[] | select(.management_mode == "terraform") | .profile] ==
    ["2C4G","4C8G","2C2G","2C2G","2C2G"]) and
  ([.resources[] | select(.management_mode == "terraform") | .agent_profile] ==
    ["1C2G","1C2G","2C2G","2C2G","2C2G"]) and
  .resources[2].capacity_type == "spot" and
  .resources[0].profile == "2C4G" and
  .resources[1].existing_node == "vault-node-0" and
  all(.resources[]; (.management_mode == "existing" or (.state_project == "svc.plus")))
' "${matrix}" >/dev/null
bash -n "${dispatcher}"

python3 - "${workflow}" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
on = doc.get("on", doc.get(True))
inputs = on["workflow_dispatch"]["inputs"]
assert inputs["target_domains"]["default"] == "all"
assert set(inputs["operation"]["options"]) >= {"plan", "apply", "deploy"}
assert "resource_orchestration" in doc["jobs"]
assert "platform-ops_dispatch-hybrid-uat-matrix.sh" in open(sys.argv[1], encoding="utf-8").read()
PY

echo "hybrid_uat_matrix_contract_test: PASS"
