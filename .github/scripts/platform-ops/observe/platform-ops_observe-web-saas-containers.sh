#!/usr/bin/env bash
set -euo pipefail

# Internal Web SaaS service-status gate.
#
# The workflow invokes this script after DNS reconciliation.  It checks the
# Doco-CD managed containers over SSH, while the calling job separately checks
# public ingress, TLS, redirects, and endpoint responses.

. "$(dirname "${BASH_SOURCE[0]}")/../provision/common_require_env.sh"
require_env MATRIX_HOST

timeout_seconds="${WEB_SAAS_CONTAINER_READY_TIMEOUT_SECONDS:-120}"
poll_seconds="${WEB_SAAS_CONTAINER_READY_POLL_SECONDS:-3}"
[[ "${timeout_seconds}" =~ ^[0-9]+$ && "${poll_seconds}" =~ ^[0-9]+$ ]] || {
  echo "::error::Container readiness timeout and poll interval must be non-negative integers." >&2
  exit 2
}

cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
[[ -f "${cmdb_file}" ]] || {
  echo "::error::CMDB file not found: ${cmdb_file}" >&2
  exit 2
}

host_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${cmdb_file}")"
[[ -n "${host_ip}" && "${host_ip}" != "null" ]] || {
  echo "::error::No IP address for ${MATRIX_HOST} in ${cmdb_file}" >&2
  exit 2
}

# These are the long-running web-saas services in gitops/compose/web-saas.
# console-assets deliberately does not appear here: it is a one-shot init
# container and a successful deployment leaves it exited with code 0.
required_containers=(
  web-saas-postgresql
  web-saas-stunnel-server
  web-saas-stunnel-client
  web-saas-accounts
  web-saas-xworkmate-bridge
  web-saas-billing
  web-saas-console
  web-saas-caddy
)

ssh_opts=(
  -i ~/.ssh/id_deploy
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=no
)

container_states() {
  local container_args=""
  printf -v container_args ' %q' "${required_containers[@]}"

  ssh "${ssh_opts[@]}" "root@${host_ip}" "bash -s --${container_args}" <<'REMOTE'
    set -eu
    for container in "$@"; do
      if ! docker inspect "$container" >/dev/null 2>&1; then
        printf "%s|missing|none\\n" "$container"
        continue
      fi
      status="$(docker inspect -f "{{.State.Status}}" "$container")"
      health="$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$container")"
      printf "%s|%s|%s\\n" "$container" "$status" "$health"
    done
REMOTE
}

all_required_containers_running() {
  local states="$1"
  local container status health required
  local not_running=()
  declare -A seen=()

  while IFS='|' read -r container status health; do
    [[ -n "${container}" ]] || continue
    seen["${container}"]=1
    [[ "${status}" == "running" ]] || not_running+=("${container}=${status}")
  done <<< "${states}"

  for required in "${required_containers[@]}"; do
    [[ -n "${seen[${required}]:-}" ]] || not_running+=("${required}=missing-state")
  done

  [[ "${#not_running[@]}" -eq 0 ]]
}

print_diagnostics() {
  echo "::group::Doco-CD and Web SaaS container diagnostics for ${MATRIX_HOST}"
  ssh "${ssh_opts[@]}" "root@${host_ip}" '
    set +e
    echo "--- web-saas container state ---"
    docker ps -a --filter "name=web-saas-" --format "table {{.Names}}\\t{{.Status}}\\t{{.Image}}" 2>&1 || true
    echo "--- Doco-CD compose state ---"
    docker compose --project-name doco-cd -f /opt/doco-cd/docker-compose.yml ps 2>&1 || true
    echo "--- Doco-CD container state ---"
    docker inspect -f "status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restart_count={{.RestartCount}}" doco-cd 2>&1 || true
    echo "--- Doco-CD recent logs ---"
    docker logs --tail 200 doco-cd 2>&1 || true
  ' 2>&1 | sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9_]+/***REDACTED_GITHUB_TOKEN***/g' \
    -e 's/hvs\.[A-Za-z0-9]+/***REDACTED_VAULT_TOKEN***/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]+/***REDACTED_SLACK_TOKEN***/g' || true
  echo "::endgroup::"
}

if ! ssh_probe="$(ssh "${ssh_opts[@]}" "root@${host_ip}" true 2>&1)"; then
  echo "::error::Cannot open an authenticated SSH session to root@${host_ip} (${MATRIX_HOST}): ${ssh_probe}" >&2
  exit 1
fi

deadline=$(( $(date +%s) + timeout_seconds ))
last_states=""
while :; do
  states="$(container_states 2>&1)" || states="ssh or docker inspection failed"
  if [[ "${states}" != "${last_states}" ]]; then
    printf '%s\n' "${states}"
    last_states="${states}"
  fi

  if all_required_containers_running "${states}"; then
    echo "Web SaaS internal containers are running on ${MATRIX_HOST}; public ingress will be verified after DNS reconciliation."
    exit 0
  fi

  [[ $(date +%s) -lt ${deadline} ]] || break
  sleep "${poll_seconds}"
done

echo "::error::Web SaaS containers did not all reach running state on ${MATRIX_HOST} within ${timeout_seconds}s." >&2
print_diagnostics
exit 1
