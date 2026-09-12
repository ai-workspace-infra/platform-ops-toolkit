#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Database Release Checkpoint & Rollback Contract Test
# ==============================================================================

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
create_script="${repo_root}/.github/scripts/database/create_release_checkpoint.sh"
restore_script="${repo_root}/.github/scripts/database/restore_release_checkpoint.sh"
serverless_wf="${repo_root}/.github/workflows/serverless-orchestrator.yml"
rollback_wf="${repo_root}/.github/workflows/rollback-orchestrator.yml"

# 1. Assert scripts exist and are executable
[[ -x "${create_script}" ]] || { echo "create_release_checkpoint.sh must be executable" >&2; exit 1; }
[[ -x "${restore_script}" ]] || { echo "restore_release_checkpoint.sh must be executable" >&2; exit 1; }

# 2. Test create script parameter validation
if RELEASE_TAG="" bash "${create_script}" >/dev/null 2>&1; then
  echo "create script must fail if RELEASE_TAG is empty" >&2
  exit 1
fi

if RELEASE_TAG="v2026.09.12" DATABASE_BACKEND="invalid" bash "${create_script}" >/dev/null 2>&1; then
  echo "create script must fail with invalid DATABASE_BACKEND" >&2
  exit 1
fi

# 3. Test restore script safety latch
if TARGET_RELEASE_TAG="v2026.09.12" CONFIRM_RESTORE="false" bash "${restore_script}" >/dev/null 2>&1; then
  echo "restore script must fail without CONFIRM_RESTORE=true" >&2
  exit 1
fi

if TARGET_RELEASE_TAG="v2026.09.12" CONFIRM_RESTORE="true" DATABASE_BACKEND="invalid" bash "${restore_script}" >/dev/null 2>&1; then
  echo "restore script must fail with invalid DATABASE_BACKEND" >&2
  exit 1
fi

# 4. Assert serverless-orchestrator.yml integrates checkpoint gate in supabase job
grep -Fq 'create_release_checkpoint.sh' "${serverless_wf}"
grep -Fq 'database-checkpoint-' "${serverless_wf}"

# 5. Assert rollback-orchestrator.yml exists and defines modes
grep -Fq 'target_release_tag' "${rollback_wf}"
grep -Fq 'rollback_mode' "${rollback_wf}"
grep -Fq 'restore_release_checkpoint.sh' "${rollback_wf}"

# 6. Assert Ledger Table definition in create script
grep -Fq 'LEDGER_TABLE="public.system_release_checkpoints"' "${create_script}"
grep -Fq 'CREATE TABLE IF NOT EXISTS ${LEDGER_TABLE}' "${create_script}"
grep -Fq 'idx_release_checkpoints_unique' "${create_script}"
grep -Fq 'checkpointed' "${create_script}"

# 7. Assert idempotent schema reset in restore script
grep -Fq 'DROP SCHEMA IF EXISTS public CASCADE' "${restore_script}"
grep -Fq 'CREATE SCHEMA IF NOT EXISTS public' "${restore_script}"
grep -Fq 'rolled_back' "${restore_script}"

echo "database_release_checkpoint_contract_test: PASS"
