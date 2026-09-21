#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
uat_role="${repo_root}/scripts/vault/templates/akamai-oidc-role-uat.json.tmpl"
prod_role="${repo_root}/scripts/vault/templates/akamai-oidc-role-prod.json.tmpl"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

python3 - "${uat_role}" "${prod_role}" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    raw = open(path, encoding="utf-8").read()
    data = json.loads(raw.replace("__ACCOUNT__", "manbuzhe2026"))
    refs = data["bound_claims"]["job_workflow_ref"]
    assert isinstance(refs, list), f"{path}: workflow claim must be an allowlist"
    assert any(ref.endswith("akamai-cloud-iac.yml@*") for ref in refs)
    assert any(ref.endswith("selfhost-orchestrator.yml@*") for ref in refs)
    if data["bound_claims"]["environment"] == "uat":
        assert any(ref.endswith("akamai-uat-migration-preflight.yml@*") for ref in refs)
print("akamai_selfhost_vault_role_contract: PASS")
PY

grep -Fq "github.event.inputs.vault_env_path == 'uat' && 'uat'" "${workflow}"
echo "akamai_selfhost_vault_role_contract: PASS"
