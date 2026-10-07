#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="$repo_root/.github/workflows/xconnect-zero-cloud.yaml"
runner="$repo_root/.github/scripts/xconnect-lab/node-observation.sh"
gateway_fragment="$repo_root/.github/scripts/xconnect-lab/remote-gateway-observation.sh"
client_fragment="$repo_root/.github/scripts/xconnect-lab/remote-client-observation.sh"

test -x "$runner"
test -f "$gateway_fragment"
test -f "$client_fragment"

python3 - "$workflow" <<'PY'
import re
import sys
from pathlib import Path

import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
triggers = document.get("on", document.get(True))
default_ref = triggers["workflow_dispatch"]["inputs"]["playbooks_ref"]["default"]
if not re.fullmatch(r"[0-9a-f]{40}", default_ref):
    raise SystemExit("playbooks_ref default must be an immutable commit SHA")

expected_source = "${{ inputs.playbooks_ref || '" + default_ref + "' }}"
for job_name in ("apply", "existing_one", "enroll_node_matrix", "cleanup"):
    job = document["jobs"][job_name]
    if job.get("env", {}).get("PLAYBOOKS_REF") != expected_source:
        raise SystemExit(f"{job_name} does not derive PLAYBOOKS_REF from the workflow default")
    checkout = next(
        (step for step in job.get("steps", [])
         if step.get("with", {}).get("repository") == "ai-workspace-infra/playbooks"),
        None,
    )
    if checkout is None or checkout.get("with", {}).get("ref") != "${{ env.PLAYBOOKS_REF }}":
        raise SystemExit(f"{job_name} must check out the selected Playbooks owner SHA")

action = next(
    (step for step in document["jobs"]["apply"]["steps"]
     if str(step.get("uses", "")).startswith("ai-workspace-infra/playbooks/.github/actions/xconnect-node-observation@")),
    None,
)
if action is None or not re.fullmatch(
    r"ai-workspace-infra/playbooks/\.github/actions/xconnect-node-observation@[0-9a-f]{40}",
    action["uses"],
):
    raise SystemExit("node observation action must use an immutable Playbooks owner SHA")
PY

grep -Fq 'observability_operations.yml' "$runner"
grep -Fq 'xconnect_remote_observation' "$runner"
grep -Fq 'inventory.ini' "$runner"
grep -Fq 'variables.json' "$runner"
grep -Fq 'trap '\''rm -rf -- "$observation_dir"'\'' EXIT' "$runner"
grep -Fq -- '--private-key "$LAB_DIR/id_ed25519"' "$runner"
grep -Fq 'UserKnownHostsFile=$LAB_DIR/known_hosts' "$runner"
grep -Fq 'xconnect_remote_observation_gateway_state_dir:"/var/lib/xconnect-gateway"' "$runner"
grep -Fq 'xconnect_remote_observation_client_state_dir:"/var/lib/xconnect-one"' "$runner"
grep -Fq 'NODE_OBSERVATION_RESULT=SUMMARY_ONLY local_independent_acceptance_required=true' "$runner"
if grep -Fq 'remote-gateway-observation.sh' "$runner" || grep -Fq 'remote-client-observation.sh' "$runner"; then
  echo 'node-observation must delegate remote checks to the Playbooks operation' >&2
  exit 1
fi
if grep -Eq 'terraform|manifest| xconnect-gateway up| xconnect sync|systemctl .*restart|service .*restart' "$runner"; then
  echo 'caller must not own Terraform/manifest or mutating remote operations' >&2
  exit 1
fi

echo 'xconnect_playbooks_observation_caller_contract_test: PASS'
