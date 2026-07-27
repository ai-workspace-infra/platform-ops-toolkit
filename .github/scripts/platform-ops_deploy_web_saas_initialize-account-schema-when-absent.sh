#!/bin/bash
set -euo pipefail

: "${MATRIX_HOST:?MATRIX_HOST must be set (pass matrix.host via step env)}"

# cmdb.json is keyed by host FQDN; resolve the target via --arg so the host name
# is expanded by the shell, not treated as a literal jq key.
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cmdb_file="${GITHUB_WORKSPACE:-${script_root}}/cmdb/cmdb.json"
[[ -f "${cmdb_file}" ]] || {
  echo "::error::CMDB file not found: ${cmdb_file}" >&2
  exit 1
}
ip="$(jq -r --arg h "${MATRIX_HOST}" '.[$h].ip' "${cmdb_file}")"
user="$(jq -r --arg h "${MATRIX_HOST}" '.[$h].ansible_user // "root"' "${cmdb_file}")"
if [ -z "${ip}" ] || [ "${ip}" = "null" ]; then
  echo "::error::host '${MATRIX_HOST}' not found in cmdb/cmdb.json (ip=${ip})" >&2
  exit 1
fi
ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes)

# Ensure 'account' database exists
ssh "${ssh_opts[@]}" "${user}@${ip}" \
  "docker exec -i postgresql psql -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = 'account'\" | grep -q 1 || docker exec -i postgresql psql -U postgres -c 'CREATE DATABASE account;'"

pg="docker exec -i postgresql psql -U postgres -d account"
has_users="$(ssh "${ssh_opts[@]}" "${user}@${ip}" \
  "$pg -tAc \"SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='users'\"" || true)"
if [ "${has_users}" = "1" ]; then
  echo "account schema already present; skipping baseline init"
else
  ssh "${ssh_opts[@]}" "${user}@${ip}" "$pg -v ON_ERROR_STOP=1 -f -" \
    < accounts-svc-plus/sql/schema.sql
  echo "account baseline schema applied"
fi
