#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
validator="${repo_root}/scripts/serverless_uat/validate_cloudflare_boundaries.py"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"

if grep -Fq 'REQUESTED_OPERATION' "${validator}" "${workflow}"; then
  echo "GitOps boundary validation must not consume a control-plane operation" >&2
  exit 1
fi

# `supabase` is a prerequisite for application deployment and combined
# deployment+migration. This catches a silently skipped preflight in the run
# graph without coupling a standalone migration to an application deploy.
if ! grep -Fq "contains(fromJSON('[\"deploy\",\"deploy+migrate\"]'), inputs.operation)" "${workflow}"; then
  echo "Supabase job must run for deploy and deploy+migrate" >&2
  exit 1
fi

if ! grep -Fq "VERIFY_SUPABASE: 'true'" "${workflow}"; then
  echo "Supabase verification must run before deployment and combined migration" >&2
  exit 1
fi

if grep -Fq '          - saas' "${workflow}"; then
  echo "Schema initialization must not remain an orchestrator operation" >&2
  exit 1
fi

for required in '          - init-schema' '  init_schema:' 'Initialize and verify Supabase account schema' "INITIALIZE_SUPABASE: 'true'" "VERIFY_SUPABASE: 'true'" 'sql/schema.sql'; do
  if ! grep -Fq "${required}" "${workflow}"; then
    echo "Serverless schema initialization operation is incomplete: ${required}" >&2
    exit 1
  fi
done

if [[ -e "${repo_root}/.github/workflows/serverless-supabase-schema-init.yml" ]]; then
  echo "Schema initialization must remain in the serverless orchestrator workflow" >&2
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
