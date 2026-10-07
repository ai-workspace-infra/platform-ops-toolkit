#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-environment-combined.sh"
target_resolver="${repo_root}/.github/scripts/snapshots/resolve-dispatch-gitops-target.sh"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

workflow_path = Path(sys.argv[1])
document = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
inputs = document[True]["workflow_dispatch"]["inputs"]
jobs = document["jobs"]

if set(inputs["deploy_env"]["options"]) != {"sit", "uat", "prod"}:
    raise SystemExit("Daily Snapshot must expose parameter-selectable sit, uat and prod environments")
for removed in (
    "enable_migration", "migration_config_json", "adopt_accounts_baseline",
    "apply_accounts_schema_migration", "accounts_schema_expected_version",
    "accounts_schema_target_version", "accounts_schema_sha256",
    "promote_prod_after_uat", "uat_daily_run_id",
):
    if removed in inputs:
        raise SystemExit(f"obsolete Daily input remains: {removed}")

for removed_job in ("resolve-accepted-uat", "promote-prod"):
    if removed_job in jobs:
        raise SystemExit(f"obsolete Daily job remains: {removed_job}")

for required_job in ("resolve-built-snapshot-tag", "shared-readiness", "resolve-dispatch-environment", "dispatch-environment", "snapshot-summary"):
    if required_job not in jobs:
        raise SystemExit(f"missing Daily job: {required_job}")

dispatch = jobs["dispatch-environment"]
if dispatch["strategy"]["matrix"] != "${{ fromJSON(needs.resolve-dispatch-environment.outputs.matrix) }}":
    raise SystemExit("Dispatch matrix must come from the selected environment output")
if "matrix.environment == (inputs.deploy_env || 'uat')" in dispatch["if"]:
    raise SystemExit("Dispatch job-level if must not reference the matrix context")
if "needs.resolve-dispatch-environment.result == 'success'" not in dispatch["if"]:
    raise SystemExit("Dispatch job must wait for the selected environment output")
if "matrix.environment" not in dispatch["name"]:
    raise SystemExit("Dispatch matrix job name must expose the selected environment")

selection = jobs["resolve-dispatch-environment"]
selection_text = " ".join(step.get("run", "") for step in selection["steps"])
for required in ("serverless-orchestrator.yml", "hybrid-orchestrator.yml", "selfhost-orchestrator.yml", "DEPLOY_ENV"):
    if required not in selection_text:
        raise SystemExit(f"environment selector missing mapping: {required}")

workflow_text = workflow_path.read_text(encoding="utf-8")
for required in (
    "resolve-dispatch-gitops-target.sh", "dispatch-environment-combined.sh",
    "aggregate-environment-dispatch-status.sh", "environment-dispatch-${{ matrix.environment }}",
    "selfhost-orchestrator.yml",
):
    if required not in workflow_text:
        raise SystemExit(f"missing environment dispatch wiring: {required}")
for removed in (
    "promote-prod", "resolve-accepted-uat", "promote-uat-snapshot-tag.sh",
    "dispatch-prod-combined.sh", "dispatch-uat-combined.sh", "uat-promotion-manifest",
    "enable_migration", "migration_config_json",
):
    if removed in workflow_text:
        raise SystemExit(f"obsolete Daily wiring remains: {removed}")

summary = jobs["snapshot-summary"]
if "always()" not in summary.get("if", ""):
    raise SystemExit("Daily summary must run for diagnostics after a dispatch failure")
if "needs.shared-readiness.result == 'failure'" not in " ".join(
    step.get("if", "") + step.get("run", "") for step in summary["steps"]
):
    raise SystemExit("Daily summary must fail when shared readiness fails")
if "needs.dispatch-environment.result == 'failure'" not in " ".join(
    step.get("if", "") + step.get("run", "") for step in summary["steps"]
):
    raise SystemExit("Daily summary must fail when the selected environment dispatch fails")
if "needs.resolve-dispatch-environment.result == 'failure'" not in " ".join(
    step.get("if", "") + step.get("run", "") for step in summary["steps"]
):
    raise SystemExit("Daily summary must fail when environment selection fails")
PY

grep -Fq 'daily-build-' "${repo_root}/.github/scripts/snapshots/resolve-daily-snapshot-tag.sh"
grep -Fq 'hybrid-orchestrator.yml' "${dispatcher}"
grep -Fq 'serverless-orchestrator.yml' "${dispatcher}"
grep -Fq 'DEPLOY_ENV' "${dispatcher}"
grep -Fq 'GITOPS_TOPOLOGY_FILE' "${target_resolver}"
if grep -Fq 'DEPLOY_ENV=uat' "${dispatcher}" || grep -Fq 'vault_env_path=uat' "${dispatcher}"; then
  echo "The generic environment dispatcher must not hardcode UAT." >&2
  exit 1
fi
grep -Fq 'Check Shared platform readiness (read-only)' "${workflow}"
grep -Fq 'check-shared-readiness.sh' "${workflow}"
if grep -Fq 'shared_platform_action' "${workflow}" || grep -Fq 'SHARED_PLATFORM_ACTION' "${dispatcher}"; then
  echo 'Daily Snapshot must not expose or dispatch Shared Terraform apply.' >&2
  exit 1
fi

echo "daily_snapshot_uat_gate_contract_test: PASS"
