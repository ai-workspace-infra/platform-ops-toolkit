#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
workflow="${repo_root}/.github/workflows/akamai-uat-migration-preflight.yml"
script="${repo_root}/.github/scripts/platform-ops/provision/akamai-uat-migration-preflight.py"
role_template="${repo_root}/scripts/vault/templates/akamai-oidc-role-uat.json.tmpl"
bootstrap="${repo_root}/scripts/vault/bootstrap_akamai_oidc_roles.sh"

python3 - "${workflow}" "${script}" "${role_template}" <<'PY'
import json
from pathlib import Path
import sys
import yaml

workflow_path, script_path, role_path = map(Path, sys.argv[1:])
workflow = yaml.load(workflow_path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
assert set(workflow["on"]) == {"workflow_dispatch"}
assert workflow["permissions"] == {"contents": "read", "id-token": "write"}
assert "push" not in workflow["on"] and "pull_request" not in workflow["on"]
assert workflow["jobs"]["inspect"]["environment"]["name"] == "uat"
steps = workflow["jobs"]["inspect"]["steps"]
checkouts = [step for step in steps if step.get("uses", "").startswith("actions/checkout@")]
assert any(step.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules" and step["with"]["ref"] == "main" for step in checkouts)
assert any(step.get("with", {}).get("repository") == "ai-workspace-infra/gitops" and step["with"]["ref"] == "main" for step in checkouts)
vault = next(step for step in steps if step.get("uses") == "hashicorp/vault-action@v4")
assert "kv/data/CICD/uat/akamai-cloud/manbuzhe2026 LINODE_TOKEN" in vault["with"]["secrets"]
assert "kv/data/CICD/uat/iac_state TF_STATE_SECRET_KEY" in vault["with"]["secrets"]
run_text = "\n".join(step.get("run", "") for step in steps)
for forbidden in ("terraform apply", "terraform destroy", "terraform import", "terraform state rm", "terraform state push", "aws s3 cp", "aws s3api delete-object"):
    assert forbidden not in run_text, forbidden
assert "state_rm_or_retire_allowed" in script_path.read_text(encoding="utf-8")
role = json.loads(role_path.read_text(encoding="utf-8").replace("__ACCOUNT__", "manbuzhe2026"))
assert any(ref.endswith("akamai-uat-migration-preflight.yml@*") for ref in role["bound_claims"]["job_workflow_ref"])
PY

grep -Fq 'preflight_workflow' "${bootstrap}"
grep -Fq 'READ_ONLY_TERRAFORM_COMMANDS' "${script}"
grep -Fq 'READ_ONLY_AWS_COMMANDS' "${script}"
grep -Fq 'legacy_state_maps_to_multiple_target_states' "${script}" || grep -Fq 'legacy_resource_maps_to_multiple_target_states' "${script}"
echo "akamai_uat_migration_preflight_contract: PASS"
