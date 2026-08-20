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
dispatch = next(step for step in summary["steps"] if step.get("name") == "Dispatch UAT serverless deploy and migration")

resolve_if = resolve.get("if", "")
for required in ("needs.snapshot.result == 'success'", "(inputs.repositories || '') == ''"):
    if required not in resolve_if:
        raise SystemExit(f"immutable tag resolution is missing full-snapshot guard: {required}")

dispatch_if = dispatch.get("if", "")
for required in ("needs.snapshot.result == 'success'", "(inputs.repositories || '') == ''"):
    if required not in dispatch_if:
        raise SystemExit(f"UAT dispatch is missing full-snapshot guard: {required}")
PY

grep -Fq 'daily-build-' "${repo_root}/.github/scripts/snapshots/resolve-daily-snapshot-tag.sh"
grep -Fq 'supabase_target_existing_strategy=accounts_merge' "${repo_root}/.github/scripts/snapshots/dispatch-uat-serverless.sh"

echo "daily_snapshot_uat_gate_contract_test: PASS"
