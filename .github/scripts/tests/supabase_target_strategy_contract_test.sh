#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/data-migration.yaml"
replace_script="${repo_root}/.github/scripts/data-migration/supabase_metadata_migration.sh"
merge_script="${repo_root}/.github/scripts/data-migration/supabase_accounts_merge_migration.sh"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

doc = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
triggers = doc.get("on", doc.get(True))

call_strategy = triggers["workflow_call"]["inputs"]["supabase_target_existing_strategy"]
if call_strategy["default"] != "reject":
    raise SystemExit("workflow_call strategy must default to reject")
if triggers["workflow_call"]["inputs"]["supabase_target_confirm_replace"]["default"] is not False:
    raise SystemExit("workflow_call replace confirmation must default to false")

dispatch_strategy = triggers["workflow_dispatch"]["inputs"]["supabase_target_existing_strategy"]
if dispatch_strategy["options"] != ["reject", "replace_public", "accounts_merge"]:
    raise SystemExit("workflow_dispatch must expose all three target strategies")
if triggers["workflow_dispatch"]["inputs"]["supabase_target_confirm_replace"]["default"] is not False:
    raise SystemExit("workflow_dispatch replace confirmation must default to false")

replace_job = doc["jobs"]["supabase_metadata_migration"]
merge_job = doc["jobs"]["supabase_accounts_merge_migration"]
if "accounts_merge" not in replace_job["if"]:
    raise SystemExit("schema migration job must exclude accounts_merge")
if "accounts_merge" not in merge_job["if"]:
    raise SystemExit("Accounts merge job must be gated on accounts_merge")
PY

grep -Fq 'TARGET_STRATEGY="${SUPABASE_TARGET_EXISTING_STRATEGY:-reject}"' "${replace_script}"
grep -Fq 'replace_public requires SUPABASE_TARGET_CONFIRM_REPLACE=true' "${replace_script}"
grep -Fq 'DROP %s IF EXISTS' "${replace_script}"
grep -Fq "server_version_num" "${replace_script}"
grep -Fq 'postgres:${server_major}' "${replace_script}"
grep -Fq 'migratectl export' "${merge_script}"
grep -Fq -- '--merge-strategy timestamp' "${merge_script}"
grep -Fq 'source DB role must remain readonly' "${merge_script}"
grep -Fq "server_version_num" "${merge_script}"
grep -Fq 'postgres:${server_major}' "${merge_script}"
grep -Fq 'Accounts merge requires SUPABASE_MIGRATION_MODE=metadata_and_data' "${merge_script}"

echo "supabase_target_strategy_contract_test: PASS"
