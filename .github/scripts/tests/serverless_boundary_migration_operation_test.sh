#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
validator="${repo_root}/scripts/serverless_uat/validate_cloudflare_boundaries.py"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"

if rg -q 'REQUESTED_OPERATION' "${validator}" "${workflow}"; then
  echo "GitOps boundary validation must not consume a control-plane operation" >&2
  exit 1
fi

REQUESTED_OPERATION=deploy+migrate python3 - "${validator}" <<'PY'
import importlib.util
import sys

validator_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("validate_cloudflare_boundaries", validator_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

module.validate_data_topology(
    {
        "primary": "serverless",
        "replica": "selfhost",
        "providers": {
            "selfhost": "self-managed-postgresql",
            "serverless": "supabase",
        },
        "migration": {
            "strategy": "async",
            "single_writer": True,
        },
    }
)
PY

echo "serverless_boundary_migration_operation_test: PASS"
