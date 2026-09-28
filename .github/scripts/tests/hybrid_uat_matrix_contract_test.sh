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
    ["open-platform","agent-proxy-jp","agent-proxy-us","agent-proxy-sg"]) and
  ([.resources[] | select(.management_mode == "existing-selfhost") | .namespace] == ["ai-workspace"]) and
  ([.resources[] | select(.management_mode == "existing") | .namespace] ==
    ["agent-proxy-tw","agent-proxy-ph"]) and
  ([.resources[] | select(.management_mode == "existing+serverless") | .namespace] == ["web-saas"]) and
  all(.resources[]; (.provider as $p | ["aws-cloud","gcp-cloud","azure-cloud","vultr-vps","akamai-cloud","ucloud","ulighthost"] | index($p) != null)) and
  all(.resources[] | select(.management_mode == "terraform"); .provider != "ulighthost") and
  all(.resources[] | select(.management_mode == "existing"); .provider == "ulighthost") and
  ([.resources[] | select(.management_mode == "terraform") | .region] ==
    ["us-east","ap-northeast-1","us-central1","sg-sin-2"]) and
  ([.resources[] | select(.management_mode == "terraform") | .profile] ==
    ["2C4G","2C2G","2C2G","2C2G"]) and
  ([.resources[] | select(.management_mode == "terraform") | .agent_profile] ==
    ["1C2G","2C2G","2C2G","2C2G"]) and
  .resources[0].profile == "2C4G" and
  .resources[0].lifecycle == "permanent" and
  .resources[1].existing_node == "vault-node-0" and
  .resources[1].lifecycle == "external" and
  .resources[2].management_mode == "existing-selfhost" and
  .resources[2].lifecycle == "external" and
  .resources[2].provider == "gcp-cloud" and
  .resources[2].profile == "4C8G" and
  .resources[2].region == "xconnect-private" and
  .resources[2].existing_host == "10.79.0.7" and
  .resources[2].xconnect_required == true and
  ([.resources[] | select(.management_mode == "terraform" and .lifecycle == "ephemeral") | .namespace] ==
    ["agent-proxy-jp","agent-proxy-us","agent-proxy-sg"]) and
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
assert set(inputs["operation"]["options"]) >= {"plan", "apply", "deploy", "destroy"}
assert "resource_orchestration" in doc["jobs"]
assert "platform-ops_dispatch-hybrid-uat-matrix.sh" in open(sys.argv[1], encoding="utf-8").read()
PY

echo "hybrid_uat_matrix_contract_test: PASS"
