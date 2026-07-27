#!/bin/bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env MATRIX_HOST ROOT_BOOTSTRAP_PASSWORD

cmdb_host="${MATRIX_HOST}"
ip="$(jq -r --arg h "${cmdb_host}" '.[$h].ip' cmdb/cmdb.json)"
user="$(jq -r --arg h "${cmdb_host}" '.[$h].ansible_user // "root"' cmdb/cmdb.json)"
if [[ -z "${ip}" || "${ip}" == "null" ]]; then
  echo "::error::host '${cmdb_host}' not found in cmdb/cmdb.json" >&2
  exit 1
fi

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes)
encoded_password="$(printf '%s' "${ROOT_BOOTSTRAP_PASSWORD}" | base64 | tr -d '\n')"

ssh "${ssh_opts[@]}" "${user}@${ip}" \
  "encoded_password='${encoded_password}' bash -s" <<'REMOTE'
set -euo pipefail
env_file=/etc/xcontrol/web-saas/secrets.env
tmp_file="${env_file}.tmp.$$"
trap 'rm -f "${tmp_file}"' EXIT

install -m 0600 /dev/null "${tmp_file}"
if [[ -f "${env_file}" ]]; then
  awk '!/^ROOT_BOOTSTRAP_PASSWORD=/' "${env_file}" > "${tmp_file}"
fi
printf '%s\n' "${encoded_password}" | base64 -d | {
  IFS= read -r password
  printf 'ROOT_BOOTSTRAP_PASSWORD=%s\n' "${password}" >> "${tmp_file}"
}
chown root:root "${tmp_file}"
mv -f "${tmp_file}" "${env_file}"

project_dir="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' accounts 2>/dev/null || true)"
config_files="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' accounts 2>/dev/null || true)"
if [[ -n "${project_dir}" && -n "${config_files}" ]]; then
  IFS=',' read -r -a compose_files <<< "${config_files}"
  compose_args=()
  for compose_file in "${compose_files[@]}"; do
    compose_args+=( -f "${compose_file}" )
  done
  docker compose "${compose_args[@]}" up -d --force-recreate accounts
else
  echo "::error::Could not resolve Compose metadata for accounts; refusing to leave the new bootstrap password unapplied." >&2
  exit 1
fi
REMOTE

echo "ROOT_BOOTSTRAP_PASSWORD synchronized and accounts recreated on ${MATRIX_HOST}."
