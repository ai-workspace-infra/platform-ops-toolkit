#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
summary = document["jobs"]["snapshot-summary"]
resolve = next(step for step in summary["steps"] if step.get("id") == "resolve_snapshot_tag")
dispatch = next(step for step in summary["steps"] if step.get("name") == "Dispatch UAT Hybrid Orchestrator")

for label, step in (("immutable tag resolution", resolve), ("hybrid UAT dispatch", dispatch)):
    condition = step.get("if", "")
    for required in ("needs.snapshot.result == 'success'", "(inputs.repositories || '') == ''"):
        if required not in condition:
            raise SystemExit(f"{label} is missing full-snapshot guard: {required}")
if dispatch.get("run") != "./.github/scripts/snapshots/dispatch-uat-combined.sh":
    raise SystemExit("UAT must use the Hybrid Orchestrator dispatcher")
PY

grep -Fq 'daily-build-' "${repo_root}/.github/scripts/snapshots/resolve-daily-snapshot-tag.sh"
grep -Fq 'hybrid-orchestrator.yml' "${dispatcher}"
grep -Fq -- '-f operation=deploy' "${dispatcher}"
grep -Fq -- '-f target_domains=all' "${dispatcher}"
grep -Fq -- '-f source_ref=main' "${dispatcher}"
if grep -Fq 'operation=destroy' "${dispatcher}"; then
  echo "Daily UAT snapshot must never dispatch destroy." >&2
  exit 1
fi
grep -Fq 'xconnect_one_release_tag:' "${workflow}"
grep -Fq 'xconnect_gateway_release_tag:' "${workflow}"
grep -Fq 'SNAPSHOT_TAG' "${dispatcher}"
grep -Fq 'promote_prod_after_uat:' "${workflow}"
grep -Fq 'promote-uat-snapshot-tag.sh' "${workflow}"
grep -Fq 'Check Shared platform readiness (read-only)' "${workflow}"
grep -Fq 'check-shared-readiness.sh' "${workflow}"
grep -Fq "steps.shared_readiness.outcome == 'success'" "${workflow}"
if grep -Fq 'shared_platform_action' "${workflow}" || grep -Fq 'SHARED_PLATFORM_ACTION' "${dispatcher}"; then
  echo 'Daily Snapshot must not expose or dispatch Shared Terraform apply.' >&2
  exit 1
fi

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
if "RELEASE_REF: ${{ inputs.snapshot_source_ref || 'main' }}" not in text:
    raise SystemExit("XConnect release must use the source ref, not the component snapshot tag")
if "client_payload[release_tag]=${RELEASE_TAG}" not in text:
    raise SystemExit("XConnect release must keep the immutable snapshot as release_tag")
PY

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = document["jobs"]
summary = jobs["snapshot-summary"]
promote = jobs.get("promote-prod")
if promote is None:
    raise SystemExit("missing promote-prod job: UAT-to-PROD promotion must be its own approval-gated job")
prod_role = "github-actions-platform-ops-toolkit-prod-release"

import json
root = Path(sys.argv[1]).resolve().parents[2]
role = json.loads((root / "scripts/vault/roles" / f"{prod_role}.json").read_text())
if role['token_policies'] != [prod_role]:
    raise SystemExit("release role must not inherit the broad production deployment policy")
if role['bound_claims']['job_workflow_ref'] != "ai-workspace-infra/platform-ops-toolkit/.github/workflows/daily-main-snapshot.yaml@refs/heads/main":
    raise SystemExit("release role workflow ref must be exact protected main")
policy = (root / "scripts/vault/policies" / f"{prod_role}.hcl").read_text()
if '"kv/data/CICD/github-app/daily-snapshot"' not in policy or any(x in policy for x in ['*', '"update"', '"create"']):
    raise SystemExit("release role must only read the exact GitHub App credential")

# The production approval must be requested only after UAT succeeded: the UAT
# job itself may be gated by `production` only for the direct PROD path.
if "promote_prod_after_uat" in summary.get("environment", ""):
    raise SystemExit("UAT job must not wait for production approval before deploying UAT")
if promote.get("environment") != "production":
    raise SystemExit("promotion must run in the production Environment")
if "snapshot-summary" not in promote.get("needs", []):
    raise SystemExit("promotion must depend on the UAT job")

condition = promote["if"]
for required in (
    "!cancelled()",
    "promote_prod_after_uat",
    "(inputs.repositories || '') == ''",
    "needs.snapshot.result == 'success'",
    "needs.snapshot-summary.result == 'success'",
    "needs.snapshot-summary.outputs.uat_hybrid_outcome == 'success'",
):
    if required not in condition:
        raise SystemExit(f"promotion is missing gate: {required}")

# Evaluate the original promotion expression across success, failure, skipped,
# cancelled, scheduled, direct-PROD and partial-snapshot scenarios.
cases = [
    ('verified UAT', 'uat', True, '', 'success', 'success', 'success', False, True),
    ('scheduled', '', False, '', 'success', 'success', 'success', False, False),
    ('not requested', 'uat', False, '', 'success', 'success', 'success', False, False),
    ('direct PROD', 'prod', True, '', 'success', 'success', 'success', False, False),
    ('partial snapshot', 'uat', True, 'portal', 'success', 'success', 'success', False, False),
    ('build failed', 'uat', True, '', 'failure', 'success', 'success', False, False),
    ('summary failed', 'uat', True, '', 'success', 'failure', 'success', False, False),
    ('Hybrid skipped', 'uat', True, '', 'success', 'success', 'skipped', False, False),
    ('Hybrid failed', 'uat', True, '', 'success', 'success', 'failure', False, False),
    ('cancelled', 'uat', True, '', 'success', 'success', 'success', True, False),
]
for name, env, requested, repos, build, result, hybrid, cancelled, expected in cases:
    expression = condition.removeprefix('${{').removesuffix('}}').strip()
    replacements = {
        '!cancelled()': repr(not cancelled),
        "(inputs.deploy_env || 'uat')": repr(env or 'uat'),
        'inputs.promote_prod_after_uat': repr(requested),
        "(inputs.repositories || '')": repr(repos),
        'needs.snapshot.result': repr(build),
        'needs.snapshot-summary.result': repr(result),
        'needs.snapshot-summary.outputs.uat_hybrid_outcome': repr(hybrid),
    }
    for atom, value in replacements.items():
        expression = expression.replace(atom, value)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    if eval(expression, {'__builtins__': {}}, {}) != expected:
        raise SystemExit(f'promotion gate truth table failed: {name}')

# The UAT job must publish the Hybrid step outcome (a skipped dispatch is not a
# verified UAT deployment) and the immutable UAT tag that gets promoted.
if summary["outputs"]["uat_hybrid_outcome"].strip() != "${{ steps.dispatch_uat_hybrid.outcome }}":
    raise SystemExit("UAT job must expose the Hybrid dispatch step outcome")
if summary["outputs"]["uat_snapshot_tag"].strip() != "${{ steps.resolve_snapshot_tag.outputs.snapshot_tag }}":
    raise SystemExit("UAT job must expose the immutable UAT tag for promotion")

steps = promote["steps"]
names = [step.get("name", "") for step in steps]


def index_of(fragment):
    return next(i for i, name in enumerate(names) if fragment in name)


# Order: readiness re-check -> credentials -> tag promotion -> PROD dispatch.
order = [index_of(f) for f in ("Re-check Shared platform readiness", "private key", "Promote verified UAT tag", "Dispatch promoted PROD")]
if order != sorted(order):
    raise SystemExit(f"promotion steps are out of order: {names}")
readiness = steps[index_of("Re-check Shared platform readiness")]
if readiness["run"] != "./.github/scripts/snapshots/check-shared-readiness.sh":
    raise SystemExit("PROD promotion must re-run the read-only Shared readiness probe")

# Only the narrow release-authoring role may mint promotion credentials.
for step in steps:
    if "vault-action" in step.get("uses", "") and step["with"]["role"] != prod_role:
        raise SystemExit(f"promotion must use {prod_role}, got {step['with']['role']}")
promote_step = steps[index_of("Promote verified UAT tag")]
if promote_step["env"]["UAT_TAG"] != "${{ needs.snapshot-summary.outputs.uat_snapshot_tag }}":
    raise SystemExit("promotion must use the UAT tag that was deployed")
dispatch_prod = steps[index_of("Dispatch promoted PROD")]
if dispatch_prod["run"] != "./.github/scripts/snapshots/dispatch-prod-combined.sh":
    raise SystemExit("PROD promotion must use the PROD dispatcher")
if "hybrid" in dispatch_prod["name"].lower():
    raise SystemExit("dispatch-prod-combined.sh fans out serverless/selfhost directly; do not label it Hybrid")
if dispatch_prod["env"]["ENABLE_MIGRATION"] not in (False, "false"):
    raise SystemExit("promoted PROD deployment must never enable data migration")

# Every child wait reads run status with the job token, which outlives the
# 60-minute GitHub App token used to dispatch; see wait-for-workflow-run.sh.
uat_dispatch = next(step for step in summary["steps"] if step.get("id") == "dispatch_uat_hybrid")
dispatch_steps = [uat_dispatch, dispatch_prod] + [
    step for step in summary["steps"] if step.get("run") == "./.github/scripts/snapshots/dispatch-prod-combined.sh"
]
for step in dispatch_steps:
    if step["env"].get("RUN_STATUS_TOKEN") != "${{ github.token }}":
        raise SystemExit(f"{step['name']} must read child run status with the job token")

# Failure diagnostics must survive a failed gate or UAT dispatch.
publish = next(step for step in summary["steps"] if step.get("name") == "Publish unified snapshot matrix summary")
if "!cancelled()" not in publish.get("if", ""):
    raise SystemExit("matrix summary must also be published when an earlier step failed")
PY

echo "daily_snapshot_uat_gate_contract_test: PASS"
