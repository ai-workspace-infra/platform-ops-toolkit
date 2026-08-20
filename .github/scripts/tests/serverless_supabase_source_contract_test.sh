#!/usr/bin/env bash
set -euo pipefail

# UAT Serverless migration is a one-way import from the production Console
# host. Sending the runner to an UAT host would export the wrong database, and
# the migration must not expose a transport override for its loopback-only DB.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys

import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
triggers = document.get("on", document.get(True))
inputs = triggers["workflow_dispatch"]["inputs"]

host = inputs["supabase_source_tunnel_host"]
if host.get("default") != "console.svc.plus":
    raise SystemExit("serverless migration source must default to console.svc.plus (PROD)")

if "supabase_source_transport" in inputs:
    raise SystemExit("serverless migration must not expose a transport override")

strategy = inputs["supabase_target_existing_strategy"]
if strategy.get("options") != ["reject", "replace_public", "accounts_merge"]:
    raise SystemExit("serverless dispatch must expose all Supabase target strategies")
if strategy.get("default") != "accounts_merge":
    raise SystemExit("serverless UAT dispatch must default to the non-destructive Accounts merge")
if inputs["supabase_target_confirm_replace"].get("default") is not False:
    raise SystemExit("serverless replace confirmation must default to false")

with_args = document["jobs"]["trigger_data_migration"]["with"]
if "supabase_source_transport" in with_args:
    raise SystemExit("serverless migration must not pass a removable transport input")
if "supabase_target_existing_strategy" not in with_args:
    raise SystemExit("serverless migration must pass the selected target strategy")
if "supabase_target_confirm_replace" not in with_args:
    raise SystemExit("serverless migration must pass replace confirmation")
if "accounts_merge" not in with_args["supabase_target_existing_strategy"]:
    raise SystemExit("serverless migration must fall back to accounts_merge when omitted")
PY

echo "serverless_supabase_source_contract_test: PASS"
