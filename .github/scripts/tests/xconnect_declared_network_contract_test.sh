#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="$repo_root/.github/workflows/xconnect-zero-cloud.yaml"
policy="$repo_root/scripts/vault/policies/github-actions-platform-ops-toolkit-shared-xconnect-network.hcl"
role="$repo_root/scripts/vault/roles/github-actions-platform-ops-toolkit-shared-xconnect-network.json"
manifest="$repo_root/.github/scripts/xconnect-network/manifest.py"
bootstrap="$repo_root/.github/scripts/xconnect-network/bootstrap.sh"

python3 - "$workflow" "$role" <<'PY'
from pathlib import Path
import sys
import json
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text())
role = json.loads(Path(sys.argv[2]).read_text())
triggers = workflow.get("on", workflow.get(True, {}))
inputs = triggers["workflow_dispatch"]["inputs"]
job = workflow["jobs"].get("declared_network")
if "declared-network" not in inputs["deployment_profile"]["options"]:
    raise SystemExit("workflow does not expose declared-network profile")
if inputs["network_environment"]["options"] != ["prod", "custom"]:
    raise SystemExit("network target must be selected as prod/custom")
if not job or job.get("environment") != "prod":
    raise SystemExit("shared network bootstrap must run in the protected prod GitHub Environment")
if "inputs.mode == 'apply'" not in job["if"] and "deployment_profile == 'declared-network'" not in job["if"]:
    raise SystemExit("declared-network job dispatch guard is missing")
if role["bound_claims"].get("environment") != "prod":
    raise SystemExit("dedicated Vault role must be bound to protected prod GitHub Environment")
if role["bound_claims"].get("job_workflow_ref") != "ai-workspace-infra/platform-ops-toolkit/.github/workflows/xconnect-zero-cloud.yaml@refs/heads/main":
    raise SystemExit("Vault role must be bound to the exact workflow on main")
print("xconnect_declared_network_contract_test: workflow and Vault role claims OK")
PY

grep -Fq 'kv/data/CICD/shared/xconnect ZERO_SERVICE_TOKEN' "$workflow"
grep -Fq 'kv/data/CICD/shared/xconnect VLESS_ID' "$workflow"
grep -Fq 'path "kv/data/CICD/github-app/daily-snapshot"' "$policy"
grep -Fq 'NETWORK_MANIFEST: gitops/${{ inputs.network_manifest }}' "$workflow"
grep -Fq 'host must belong to an approved svc.plus or onwalk.net service domain' "$manifest"
grep -Fq 'kv/data/CICD/shared/xconnect-operator-invite/*' "$policy"
if grep -Fq 'path "kv/data/CICD/shared/xconnect-operator-invite/*"' "$policy" && grep -A2 -Fq 'path "kv/data/CICD/shared/xconnect-operator-invite/*"' "$policy"; then
  grep -A2 -F 'path "kv/data/CICD/shared/xconnect-operator-invite/*"' "$policy" | grep -Fq 'capabilities = ["create", "update"]'
fi
python3 - "$policy" <<'PY'
from pathlib import Path
import re
import sys

policy = Path(sys.argv[1]).read_text()
match = re.search(r'path "kv/data/CICD/shared/xconnect-operator-invite/\*"\s*\{([^}]*)\}', policy, re.S)
if not match or 'capabilities = ["create", "update"]' not in match.group(1):
    raise SystemExit("per-network invitation path must be write-only from CI")
if 'read' in match.group(1):
    raise SystemExit("CI must not read its one-use invitation")
PY
! grep -Fq 'VAULT_JWT: ${{ github.token }}' "$workflow"
grep -Fq 'ACTIONS_ID_TOKEN_REQUEST_TOKEN' "$bootstrap"
grep -Fq 'startswith("xconnect://join/")' "$bootstrap"
grep -Fq 'del(.bootstrap.invite.ttl_minutes)' "$bootstrap"
grep -Fq 'GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}' "$bootstrap"
grep -Fq 'workflow_dispatch' "$workflow"

echo 'xconnect_declared_network_contract_test: PASS'
