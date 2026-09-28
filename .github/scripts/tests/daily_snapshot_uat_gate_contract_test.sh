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
