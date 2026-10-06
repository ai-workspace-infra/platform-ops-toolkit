#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

workflow_path = Path(sys.argv[1])
document = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
inputs = document[True]["workflow_dispatch"]["inputs"]
jobs = document["jobs"]
summary = jobs["snapshot-summary"]
resolve = next(step for step in summary["steps"] if step.get("id") == "resolve_snapshot_tag")
dispatch = next(step for step in summary["steps"] if step.get("name") == "Dispatch UAT Hybrid Orchestrator")

if set(inputs["deploy_env"]["options"]) != {"sit", "uat", "prod"}:
    raise SystemExit("Daily Snapshot must expose sit, uat and the guarded prod promotion route")
for required in ("promote_prod_after_uat", "uat_daily_run_id"):
    if required not in inputs:
        raise SystemExit(f"Daily PROD promotion input is missing: {required}")

for required_job in ("resolve-accepted-uat", "promote-prod"):
    if required_job not in jobs:
        raise SystemExit(f"Daily PROD promotion job is missing: {required_job}")

for label, step in (("immutable tag resolution", resolve), ("hybrid UAT dispatch", dispatch)):
    condition = step.get("if", "")
    for required in ("needs.snapshot.result == 'success'", "(inputs.repositories || '') == ''"):
        if required not in condition:
            raise SystemExit(f"{label} is missing full-snapshot guard: {required}")
if dispatch.get("run") != "./.github/scripts/snapshots/dispatch-uat-combined.sh":
    raise SystemExit("UAT must use the Hybrid Orchestrator dispatcher")

upload = next(step for step in summary["steps"] if step.get("name") == "Upload the verified UAT promotion manifest")
if "steps.dispatch_uat_hybrid.outputs.promotion_manifest_verified == 'true'" not in upload.get("if", ""):
    raise SystemExit("Preview success must not require a deployment promotion manifest")

workflow_text = workflow_path.read_text(encoding="utf-8")
for removed in (
    "promote-uat-snapshot-tag.sh",
    "dispatch-prod-combined.sh",
    "uat-promotion-manifest",
):
    if removed not in workflow_text:
        raise SystemExit(f"Daily PROD promotion wiring is missing: {removed}")

prod = jobs["promote-prod"]
if prod.get("environment") != "production":
    raise SystemExit("PROD promotion must wait on the production Environment")
if "uat_daily_run_id" not in workflow_text:
    raise SystemExit("PROD promotion must identify the accepted UAT Daily run")
if "UAT_PROMOTION_MANIFEST_FILE" not in workflow_text:
    raise SystemExit("UAT must upload the verified promotion manifest")
if "ENABLE_MIGRATION: false" not in workflow_text:
    raise SystemExit("PROD promotion must not enable implicit data migration")
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

echo "daily_snapshot_uat_gate_contract_test: PASS"
