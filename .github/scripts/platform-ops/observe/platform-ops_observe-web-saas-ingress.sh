#!/usr/bin/env bash
set -euo pipefail

# Post-DNS diagnostic only. The internal-container gate remains the sole
# pre-DNS readiness condition; this script prints the facts needed to explain
# a failed public HTTPS probe and never replaces that gate.

. "$(dirname "${BASH_SOURCE[0]}")/../provision/common_require_env.sh"
require_env MATRIX_HOST

cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
if [[ ! -f "${cmdb_file}" ]]; then
  echo "::warning::CMDB file not found: ${cmdb_file}" >&2
  exit 0
fi

host_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${cmdb_file}")"
if [[ -z "${host_ip}" || "${host_ip}" == "null" ]]; then
  echo "::warning::No CMDB IP address for ${MATRIX_HOST}; skipping Web SaaS ingress diagnostics." >&2
  exit 0
fi

ssh_opts=(
  -i ~/.ssh/id_deploy
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=no
)

echo "::group::Web SaaS ingress diagnostics for ${MATRIX_HOST} (${host_ip})"
set +e
ssh "${ssh_opts[@]}" "root@${host_ip}" 'bash -s' <<'REMOTE' 2>&1 | sed -E \
  -e 's/gh[pousr]_[A-Za-z0-9_]+/***REDACTED_GITHUB_TOKEN***/g' \
  -e 's/hvs\.[A-Za-z0-9]+/***REDACTED_VAULT_TOKEN***/g' \
  -e 's/xox[baprs]-[A-Za-z0-9-]+/***REDACTED_SLACK_TOKEN***/g'
set +e

echo '--- container state and published ports ---'
docker ps -a --filter 'name=^web-saas-caddy$' \
  --format 'name={{.Names}} status={{.Status}} image={{.Image}} ports={{.Ports}}'
docker inspect web-saas-caddy --format \
  'state={{.State.Status}} running={{.State.Running}} restart_count={{.RestartCount}} started_at={{.State.StartedAt}}'
docker port web-saas-caddy

echo '--- host listeners on 80/443 ---'
ss -ltnp '( sport = :80 or sport = :443 )'

echo '--- Caddyfile inside the container (comments omitted) ---'
docker exec web-saas-caddy sh -c \
  "sed -E '/^[[:space:]]*(#|$)/d' /etc/caddy/Caddyfile" 2>&1

echo '--- Caddy config validation ---'
docker exec web-saas-caddy caddy validate --config /etc/caddy/Caddyfile 2>&1

echo '--- local HTTPS probe with UAT SNI ---'
curl -k -sS -D - -o /dev/null --connect-timeout 5 --max-time 10 \
  --resolve console-uat.onwalk.net:443:127.0.0.1 \
  https://console-uat.onwalk.net/ 2>&1

echo '--- web-saas-caddy recent logs ---'
docker logs --tail 160 web-saas-caddy 2>&1
REMOTE
ssh_exit=${PIPESTATUS[0]}
set -e
echo "::endgroup::"

if [[ "${ssh_exit}" -ne 0 ]]; then
  echo "::warning::Unable to collect Web SaaS ingress diagnostics from ${MATRIX_HOST} (ssh exit ${ssh_exit})." >&2
fi

# The external endpoint step remains the actual post-DNS gate.
exit 0
