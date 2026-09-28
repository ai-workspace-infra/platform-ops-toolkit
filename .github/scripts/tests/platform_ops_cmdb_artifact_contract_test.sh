#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq -- '- name: Stage CMDB artifact' "${workflow}"
grep -Fq -- 'CMDB_STAGE_DIR: ${{ runner.temp }}/cmdb-artifact' "${workflow}"
grep -Fq -- 'cp "${source_dir}/${file}" "${CMDB_STAGE_DIR}/${file}"' "${workflow}"
grep -Fq -- 'path: ${{ runner.temp }}/cmdb-artifact' "${workflow}"
grep -Fq -- 'if-no-files-found: error' "${workflow}"

echo "platform_ops_cmdb_artifact_contract: PASS"
