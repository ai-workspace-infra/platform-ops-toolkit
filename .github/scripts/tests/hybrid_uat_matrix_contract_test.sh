#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
matrix="${GITOPS_MATRIX_FILE:?GITOPS_MATRIX_FILE must point to the GitOps resource matrix}"
dispatcher="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_dispatch-hybrid-uat-matrix.sh"
workflow="${repo_root}/.github/workflows/hybrid-orchestrator.yml"

jq -e '
  .kind == "ResourceMatrix" and .metadata.environment == "uat" and
  (.spec.target_domains == "all") and
  ([.spec.resources[].order] == [1,2,3,4,5,6,7,8]) and
  ([.spec.resources[] | select(.management_mode == "terraform" or .management_mode == "terraform+serverless") | .namespace] ==
    ["open-platform","web-saas","ai-workspace","agent-proxy-jp","agent-proxy-us","agent-proxy-sg"]) and
  ([.spec.resources[] | select(.management_mode == "existing-selfhost") | .namespace] == []) and
  ([.spec.resources[] | select(.management_mode == "existing") | .namespace] ==
    ["agent-proxy-tw","agent-proxy-ph"]) and
  ([.spec.resources[] | select(.management_mode == "terraform+serverless") | .namespace] == ["web-saas"]) and
  all(.spec.resources[]; (.provider as $p | ["aws-cloud","gcp-cloud","azure-cloud","vultr-vps","akamai-cloud","ucloud","ulighthost"] | index($p) != null)) and
  all(.spec.resources[] | select(.management_mode == "terraform"); .provider != "ulighthost") and
  all(.spec.resources[] | select(.management_mode == "existing"); .provider == "ulighthost") and
  ([.spec.resources[] | select(.management_mode == "terraform" or .management_mode == "terraform+serverless") | .region] ==
    ["asia-east1","asia-east1","asia-east1","ap-northeast-1","us-central1","sg-sin-2"]) and
  ([.spec.resources[] | select(.management_mode == "terraform" or .management_mode == "terraform+serverless") | .provider] ==
    ["gcp-cloud","gcp-cloud","gcp-cloud","aws-cloud","gcp-cloud","akamai-cloud"]) and
  ([.spec.resources[] | select(.management_mode == "terraform" or .management_mode == "terraform+serverless") | .profile] ==
    ["2C4G","2C4G","4C8G","2C2G","2C2G","2C2G"]) and
  ([.spec.resources[] | select(.management_mode == "terraform" or .management_mode == "terraform+serverless") | (.agent_profile // "1C2G")] ==
    ["1C2G","1C2G","1C2G","2C2G","2C2G","2C2G"]) and
  .spec.resources[0].profile == "2C4G" and
  .spec.resources[0].account_ref == "gcp_account" and
  (.spec.resources[0].account == null) and
  .spec.resources[0].project_id == "open-platform-uat" and
  .spec.resources[0].lifecycle == "permanent" and
  .spec.resources[0].release_scope == "shared-infrastructure" and
  .spec.resources[0].xconnect_required == true and
  .spec.resources[0].xconnect_gateway_ref == "tw-xconnect.svc.plus" and
  .spec.resources[0].vault_cluster_environment == "prod" and
  .spec.resources[0].vault_cluster_role == "prod-member" and
  all(.spec.resources[]; (.release_scope == "business" or .release_scope == "shared-infrastructure")) and
  ([.spec.resources[] | select(.release_scope == "business") | .namespace] ==
    ["web-saas","ai-workspace","agent-proxy-jp","agent-proxy-us","agent-proxy-sg","agent-proxy-tw","agent-proxy-ph"]) and
  .spec.resources[1].management_mode == "terraform+serverless" and
  .spec.resources[1].lifecycle == "ephemeral" and
  .spec.resources[2].management_mode == "terraform" and
  .spec.resources[2].lifecycle == "ephemeral" and
  .spec.resources[2].provider == "gcp-cloud" and
  .spec.resources[2].profile == "4C8G" and
  .spec.resources[2].region == "asia-east1" and
  .spec.resources[2].capacity_type == "spot" and
  (.spec.resources[2].existing_host == null) and
  .spec.xconnect_network.id == "net_uat" and
  .spec.xconnect_network.gateway_ref == "tw-xconnect.svc.plus" and
  .spec.xconnect_network.gateway_vault_key == "tw-xconnect.svc.plus" and
  .spec.xconnect_network.one_vault_key == "observability.svc.plus" and
  ([.spec.resources[] | select((.management_mode == "terraform" or .management_mode == "terraform+serverless") and .lifecycle == "ephemeral") | .namespace] ==
    ["web-saas","ai-workspace","agent-proxy-jp","agent-proxy-us","agent-proxy-sg"]) and
  all(.spec.resources[]; (.management_mode == "existing" or (.state_project == "svc.plus")))
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
XCONNECT_MIGRATION=true \
DRY_RUN=true \
bash "${dispatcher}" >"${dry_run}"

line_for() { grep -nF -- "$1" "${dry_run}" | head -n1 | cut -d: -f1; }
jp_line="$(line_for 'DRY-RUN agent-proxy-jp (aws-cloud, 2C2G')"
us_line="$(line_for 'DRY-RUN agent-proxy-us (gcp-cloud, 2C2G')"
sg_line="$(line_for 'DRY-RUN agent-proxy-sg (akamai-cloud, 2C2G')"
web_line="$(line_for 'DRY-RUN web-saas serverless')"
ai_line="$(line_for 'DRY-RUN ai-workspace (gcp-cloud, 4C8G')"
tw_line="$(line_for 'DRY-RUN agent-proxy-tw (existing inventory)')"
ph_line="$(line_for 'DRY-RUN agent-proxy-ph (existing inventory)')"
[[ -n "${jp_line}${us_line}${sg_line}${web_line}${ai_line}${tw_line}${ph_line}" ]] || {
  echo "hybrid deploy dry-run is missing a required business phase or lane" >&2
  exit 1
}
(( ai_line < jp_line && jp_line < us_line && us_line < sg_line && sg_line < web_line && web_line < tw_line && tw_line < ph_line )) || {
  echo "hybrid deploy must follow the GitOps matrix order after the XConnect gate" >&2
  exit 1
}
if grep -Fq 'DRY-RUN open-platform' "${dry_run}"; then
  echo "UAT hybrid deploy must not reprovision shared open-platform resources" >&2
  exit 1
fi
xc_line="$(line_for 'DRY-RUN XConnect Zero UAT (tw-xconnect.svc.plus)')"
[[ -n "${xc_line}" ]] || {
  echo "hybrid deploy must dispatch the configurable XConnect gate" >&2
  exit 1
}
grep -Eq '"network_id"[[:space:]]*:[[:space:]]*"net_uat"' "${dry_run}" || {
  echo "hybrid deploy must pass the GitOps XConnect network identity" >&2
  exit 1
}
(( sg_line < xc_line && xc_line < web_line )) || {
  echo "XConnect gate must run after Terraform readiness and before applications" >&2
  exit 1
}
if grep -Fq '10.79.0.7' "${dry_run}"; then
  echo "hybrid deploy must not route AI Workspace through the retired private host" >&2
  exit 1
fi

python3 - "${workflow}" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
on = doc.get("on", doc.get(True))
inputs = on["workflow_dispatch"]["inputs"]
assert inputs["target_domains"]["default"] == "all"
assert set(inputs["operation"]["options"]) >= {"plan", "apply", "deploy", "destroy"}
assert inputs["xconnect_migration"]["default"] is False
assert "CHILD_REF: ${{ inputs.source_ref || 'main' }}" in open(sys.argv[1], encoding="utf-8").read()
assert "resource_orchestration" in doc["jobs"]
assert "platform-ops_dispatch-hybrid-uat-matrix.sh" in open(sys.argv[1], encoding="utf-8").read()
PY

echo "hybrid_uat_matrix_contract_test: PASS"
