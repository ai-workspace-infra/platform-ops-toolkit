#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq -- '- name: Stage CMDB artifact' "${workflow}"
grep -Fq -- 'CMDB_STAGE_DIR: ${{ runner.temp }}/cmdb-artifact' "${workflow}"
grep -Fq -- 'for file in cmdb.json inventory.ini; do' "${workflow}"
grep -Fq -- 'cp "${source_dir}/${file}" "${CMDB_STAGE_DIR}/${file}"' "${workflow}"
grep -Fq -- 'if [[ -f "${source_dir}/hosts_manifest.json" ]]; then' "${workflow}"
grep -Fq -- 'path: ${{ runner.temp }}/cmdb-artifact' "${workflow}"
grep -Fq -- 'if-no-files-found: error' "${workflow}"
grep -Fq -- 'CMDB_FILE: ${{ runner.temp }}/uat-dns-cmdb.json' "${workflow}"
grep -Fq -- 'with_entries(select((.value | type) == "object") | select((.value.groups | type) == "array"))' "${workflow}"

# The UAT DNS executor consumes a host-only CMDB projection; artifact metadata
# may include strings and objects that are not inventory hosts.
jq -n -e '
  {environment:"uat", cloud_run_uri:null, web:{groups:["web_saas"],ip:"192.0.2.1"}}
  | with_entries(select((.value | type) == "object") | select((.value.groups | type) == "array"))
  | keys == ["web"]
' >/dev/null

echo "platform_ops_cmdb_artifact_contract: PASS"
