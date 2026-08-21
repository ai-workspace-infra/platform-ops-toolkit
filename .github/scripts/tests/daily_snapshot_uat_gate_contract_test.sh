#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
summary = document["jobs"]["snapshot-summary"]
resolve = next(step for step in summary["steps"] if step.get("id") == "resolve_snapshot_tag")
dispatch = next(step for step in summary["steps"] if step.get("name") == "Dispatch UAT serverless and selfhost agent-proxy")

for label, step in (("immutable tag resolution", resolve), ("combined UAT dispatch", dispatch)):
    condition = step.get("if", "")
    for required in ("needs.snapshot.result == 'success'", "(inputs.repositories || '') == ''"):
        if required not in condition:
            raise SystemExit(f"{label} is missing full-snapshot guard: {required}")

if dispatch.get("run") != "./.github/scripts/snapshots/dispatch-uat-combined.sh":
    raise SystemExit("UAT must use the combined serverless/selfhost dispatcher")
PY

grep -Fq 'daily-build-' "${repo_root}/.github/scripts/snapshots/resolve-daily-snapshot-tag.sh"
grep -Fq 'supabase_target_existing_strategy=accounts_merge' "${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
grep -Fq 'dns_mode=uat-records' "${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
grep -Fq 'target_domains=agent-proxy' "${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
grep -Fq 'agent_controller_url' "${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"

echo "daily_snapshot_uat_gate_contract_test: PASS"
