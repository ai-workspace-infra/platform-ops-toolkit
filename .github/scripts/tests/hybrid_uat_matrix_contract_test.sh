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
    ["asia-east1","ap-northeast-1","us-central1","sg-sin-2"]) and
  ([.resources[] | select(.management_mode == "terraform") | .provider] ==
    ["gcp-cloud","aws-cloud","gcp-cloud","akamai-cloud"]) and
  ([.resources[] | select(.management_mode == "terraform") | .profile] ==
    ["2C4G","2C2G","2C2G","2C2G"]) and
  ([.resources[] | select(.management_mode == "terraform") | .agent_profile] ==
    ["1C2G","2C2G","2C2G","2C2G"]) and
  .resources[0].profile == "2C4G" and
  .resources[0].lifecycle == "permanent" and
  .resources[0].release_scope == "shared-infrastructure" and
  all(.resources[]; (.release_scope == "business" or .release_scope == "shared-infrastructure")) and
  ([.resources[] | select(.release_scope == "business") | .namespace] ==
    ["web-saas","ai-workspace","agent-proxy-jp","agent-proxy-us","agent-proxy-sg","agent-proxy-tw","agent-proxy-ph"]) and
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

dry_run="$(mktemp)"
trap 'rm -f "${dry_run}"' EXIT
GH_TOKEN=dry-run \
GH_REPO=ai-workspace-infra/platform-ops-toolkit \
MATRIX_FILE="${matrix}" \
OPERATION=deploy \
CHILD_REF=main \
VAULT_ENV_PATH=uat \
TARGET_DOMAIN_BASE=onwalk.net \
OBSERVABILITY_ENDPOINT=https://observability.svc.plus \
AKAMAI_ACCOUNT=manbuzhe2026 \
AWS_ACCOUNT=081434641398 \
GCP_ACCOUNT=xworktech \
EXISTING_ACCOUNT=ucloud-ulighthost \
SOURCE_REF=main \
DEPLOY_TAG=uat-daily-build-2026.09.28-r1 \
VAULT_ADDR=https://vault.svc.plus \
XCONNECT_GATEWAY_REF=tw-xconnect.svc.plus \
DRY_RUN=true \
bash "${dispatcher}" >"${dry_run}"

line_for() { grep -nF -- "$1" "${dry_run}" | head -n1 | cut -d: -f1; }
jp_line="$(line_for 'DRY-RUN agent-proxy-jp (aws-cloud, 2C2G')"
us_line="$(line_for 'DRY-RUN agent-proxy-us (gcp-cloud, 2C2G')"
sg_line="$(line_for 'DRY-RUN agent-proxy-sg (akamai-cloud, 2C2G')"
xconnect_line="$(line_for 'DRY-RUN XConnect Zero UAT (tw-xconnect.svc.plus)')"
web_line="$(line_for 'DRY-RUN web-saas serverless')"
ai_line="$(line_for 'DRY-RUN ai-workspace (gcp-cloud, 4C8G')"
tw_line="$(line_for 'DRY-RUN agent-proxy-tw (existing inventory)')"
ph_line="$(line_for 'DRY-RUN agent-proxy-ph (existing inventory)')"
[[ -n "${jp_line}${us_line}${sg_line}${xconnect_line}${web_line}${ai_line}${tw_line}${ph_line}" ]] || {
  echo "hybrid deploy dry-run is missing a required business phase or lane" >&2
  exit 1
}
(( jp_line < us_line && us_line < sg_line && sg_line < xconnect_line && xconnect_line < web_line && web_line < ai_line && ai_line < tw_line && tw_line < ph_line )) || {
  echo "hybrid deploy must finish all Terraform lanes before the XConnect gate" >&2
  exit 1
}
if grep -Fq 'DRY-RUN open-platform' "${dry_run}"; then
  echo "routine UAT hybrid deploy must not dispatch shared open-platform services" >&2
  exit 1
fi
grep -Fq 'existing_target_host": "10.79.0.7"' "${dry_run}" || {
  echo "hybrid deploy must pass the protected AI Workspace existing host" >&2
  exit 1
}

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
