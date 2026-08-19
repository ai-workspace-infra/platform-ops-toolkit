#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/data-migration/supabase_metadata_migration.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

if MIGRATION_SOURCE_DSN='postgres://readonly:password@127.0.0.1:15433/account?sslmode=disable' \
  SUPABASE_TARGET_DSN='postgres://postgres.project:password@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres?sslmode=require' \
  SUPABASE_VAULT_PROJECT_REF='project' \
  SUPABASE_METADATA_DRY_RUN=true \
  bash "${script}" >"${test_dir}/output" 2>&1; then
  echo "Expected loopback migration source DSN to be rejected" >&2
  exit 1
fi

grep -Fq 'MIGRATION_SOURCE_DSN targets runner loopback' "${test_dir}/output"
grep -Fq 'reachable, read-only VPS PostgreSQL DSN' "${test_dir}/output"

echo "supabase_metadata_migration_source_guard_test: PASS"
