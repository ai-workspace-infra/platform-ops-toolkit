#!/usr/bin/env bash
set -euo pipefail

# UAT Serverless migration is a one-way import from the production Console
# host.  Sending the runner to an UAT host would export the wrong database,
# while stunnel is intentionally not public to GitHub-hosted runners.

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
    raise SystemExit("serverless migration must not expose a stunnel override for the loopback-only PROD source")

with_args = document["jobs"]["trigger_data_migration"]["with"]
if with_args.get("supabase_source_transport") != "ssh":
    raise SystemExit("serverless migration must force SSH to the PROD source")
PY

echo "serverless_supabase_source_contract_test: PASS"
