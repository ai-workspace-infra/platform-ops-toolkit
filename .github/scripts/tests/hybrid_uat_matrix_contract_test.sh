#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
matrix="${GITOPS_MATRIX_FILE:?GITOPS_MATRIX_FILE must point to the GitOps resource matrix}"
open_platform="${GITOPS_OPEN_PLATFORM_FILE:?GITOPS_OPEN_PLATFORM_FILE must point to the UAT open-platform declaration}"
resource_roots="${GITOPS_RESOURCE_ROOTS:?GITOPS_RESOURCE_ROOTS must contain the GitOps GCP workload declaration roots}"
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

MATRIX_FILE="${matrix}" OPEN_PLATFORM_FILE="${open_platform}" RESOURCE_ROOTS="${resource_roots}" python3 - <<'PY'
import json
import os
from pathlib import Path

import yaml

matrix = json.loads(Path(os.environ["MATRIX_FILE"]).read_text(encoding="utf-8"))
platform_path = Path(os.environ["OPEN_PLATFORM_FILE"])
platform = yaml.safe_load(platform_path.read_text(encoding="utf-8")) or {}
global_config = platform.get("global") or {}
project_id = global_config.get("project_id")
if project_id != "open-platform-uat":
    raise SystemExit(f"UAT open-platform policy must target open-platform-uat, got {project_id!r}")

allowlist = global_config.get("external_ip_allowed_instances")
if not isinstance(allowlist, list) or not allowlist:
    raise SystemExit("UAT open-platform must declare a non-empty external_ip_allowed_instances allowlist")
allowlisted = set()
for item in allowlist:
    if not isinstance(item, dict) or not item.get("name") or not item.get("zone"):
        raise SystemExit("UAT external_ip_allowed_instances entries must contain name and zone")
    key = (item["name"], item["zone"])
    if key in allowlisted:
        raise SystemExit(f"duplicate UAT external-IP allowlist entry: {key[0]} in {key[1]}")
    allowlisted.add(key)

roots = [Path(value) for value in os.environ["RESOURCE_ROOTS"].split(":") if value]
expected = []
for row in matrix["spec"]["resources"]:
    namespace = row["namespace"]
    if namespace == "open-platform":
        for node in global_config.get("vault_nodes", []):
            if node.get("public_ip"):
                expected.append((node["name"], node["zone"], namespace))
        continue
    if row.get("provider") != "gcp-cloud" or row.get("management_mode") not in {"terraform", "terraform+serverless"}:
        continue
    manifest_path = next((root / f"{namespace}.yaml" for root in roots if (root / f"{namespace}.yaml").is_file()), None)
    if manifest_path is None:
        raise SystemExit(f"missing GitOps GCP workload declaration for matrix namespace {namespace}")
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    spec = manifest.get("spec") or {}
    if spec.get("project_id") != project_id:
        raise SystemExit(f"{namespace} does not target {project_id}: {spec.get('project_id')!r}")
    for vm in (spec.get("resources") or {}).get("spot_vms", []):
        if vm.get("public_ip"):
            expected.append((vm["name"], vm["zone"], namespace))

missing = [(name, zone, namespace) for name, zone, namespace in expected if (name, zone) not in allowlisted]
if missing:
    details = ", ".join(f"{name} in {zone} ({namespace})" for name, zone, namespace in missing)
    raise SystemExit(f"UAT public-IP workload is absent from the open-platform policy allowlist: {details}")
PY

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
open_platform_line="$(line_for 'DRY-RUN open-platform (gcp-cloud, 2C4G')"
tw_line="$(line_for 'DRY-RUN agent-proxy-tw (existing inventory)')"
ph_line="$(line_for 'DRY-RUN agent-proxy-ph (existing inventory)')"
[[ -n "${open_platform_line}${jp_line}${us_line}${sg_line}${web_line}${ai_line}${tw_line}${ph_line}" ]] || {
  echo "hybrid deploy dry-run is missing a required platform prerequisite or business lane" >&2
  exit 1
}
(( open_platform_line < ai_line && ai_line < jp_line && jp_line < us_line && us_line < sg_line && sg_line < web_line && web_line < tw_line && tw_line < ph_line )) || {
  echo "hybrid deploy must reconcile the UAT platform before business lanes" >&2
  exit 1
}

for operation in plan apply destroy; do
  non_deploy_output="$(
    GH_TOKEN=dry-run \
    GH_REPO=ai-workspace-infra/platform-ops-toolkit \
    MATRIX_FILE="${matrix}" \
    OPERATION="${operation}" \
    CHILD_REF=main \
    VAULT_ENV_PATH=uat \
    TARGET_DOMAIN_BASE=onwalk.net \
    OBSERVABILITY_ENDPOINT=https://observability.svc.plus \
    AKAMAI_ACCOUNT=manbuzhe2026 \
    AWS_ACCOUNT=081434641398 \
    GCP_ACCOUNT=xworktech \
    EXISTING_ACCOUNT=ucloud-ulighthost \
    SOURCE_REF=main \
    DEPLOY_TAG= \
    VAULT_ADDR=https://vault.svc.plus \
    XCONNECT_GATEWAY_REF=tw-xconnect.svc.plus \
    XCONNECT_MIGRATION=false \
    DRY_RUN=true \
    bash "${dispatcher}"
  )"
  if grep -Fq 'DRY-RUN open-platform' <<<"${non_deploy_output}"; then
    echo "Hybrid ${operation} must not touch shared open-platform resources" >&2
    exit 1
  fi
done

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

python3 - "${workflow}" "${dispatcher}" <<'PY'
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
resource_job = doc["jobs"]["resource_orchestration"]
assert "needs.preflight.result == 'success'" in resource_job["if"]
edge_job = doc["jobs"]["edge_gateway"]
assert edge_job["needs"] == "resource_orchestration"
assert "needs.resource_orchestration.result == 'success'" in edge_job["if"]
verify_job = doc["jobs"]["verify"]
assert "needs.resource_orchestration.result == 'success'" in verify_job["if"]
assert "needs.edge_gateway.result == 'success'" in verify_job["if"]
dispatcher_text = open(sys.argv[2], encoding="utf-8").read()
assert 'gh run watch "${run_id}"' in dispatcher_text
assert "--exit-status" in dispatcher_text
assert 'gh run view "${run_id}"' in dispatcher_text
selfhost = yaml.safe_load(open(".github/workflows/selfhost-orchestrator.yml", encoding="utf-8"))
steps = selfhost["jobs"]["provision"]["steps"]
adopt = next(step for step in steps if step.get("name") == "Adopt existing UAT external IP policy into open-platform state")
assert "terraform_namespace == 'open-platform'" in adopt["if"]
assert 'google_org_policy_policy.vm_external_ip_access' in adopt["run"]
assert 'module.open_platform_uat.google_compute_address.public[0]' in adopt["run"]
assert 'module.open_platform_uat.google_service_account.runtime' in adopt["run"]
assert " import -input=false" in adopt["run"]
assert steps.index(adopt) < next(i for i, step in enumerate(steps) if step.get("name") == "Terraform Plan / Apply / Destroy")
apply_script = open('.github/scripts/platform-ops/provision/platform-ops_provision_terraform-apply-destroy.sh', encoding='utf-8').read()
assert 'ENV_STEPS_ROUTE_OUTPUTS_STATE_KEY:-}' in apply_script
assert 'index("delete")' in apply_script
PY

echo "hybrid_uat_matrix_contract_test: PASS"
