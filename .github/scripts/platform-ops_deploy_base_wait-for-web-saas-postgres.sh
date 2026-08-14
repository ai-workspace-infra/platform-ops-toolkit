#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env MATRIX_HOST

timeout_seconds="${WEB_SAAS_POSTGRES_READY_TIMEOUT_SECONDS:-300}"
poll_seconds="${WEB_SAAS_POSTGRES_READY_POLL_SECONDS:-10}"
[[ "${timeout_seconds}" =~ ^[0-9]+$ && "${poll_seconds}" =~ ^[0-9]+$ ]] || {
  echo "::error::Readiness timeout and poll interval must be non-negative integers." >&2
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

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=no
)

postgres_state() {
  ssh "${ssh_opts[@]}" "root@${host_ip}" '
    set -eu
    if ! docker inspect web-saas-postgresql >/dev/null 2>&1; then
      printf "missing\\n"
      exit 0
    fi
    status="$(docker inspect -f "{{.State.Status}}" web-saas-postgresql)"
    health="$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" web-saas-postgresql)"
    printf "%s %s\\n" "$status" "$health"
  '
}

print_diagnostics() {
  echo "::group::Doco-CD and Web SaaS diagnostics for ${MATRIX_HOST}"
  # These are intentionally read-only. Redact common access-token shapes before
  # forwarding remote container logs into GitHub Actions.
  ssh "${ssh_opts[@]}" "root@${host_ip}" '
    set +e
    echo "--- web-saas-postgresql state ---"
    docker inspect -f "status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} started={{.State.StartedAt}} exit_code={{.State.ExitCode}} error={{.State.Error}}" web-saas-postgresql 2>&1 || true
    echo "--- web-saas containers ---"
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

deadline=$(( $(date +%s) + timeout_seconds ))
last_state="unavailable"
while :; do
  last_state="$(postgres_state 2>&1)" || last_state="ssh or docker inspection failed"
  if [[ "${last_state}" == "running healthy" ]]; then
    echo "web-saas-postgresql is running and healthy on ${MATRIX_HOST}."
    exit 0
  fi

  [[ $(date +%s) -lt ${deadline} ]] || break
  sleep "${poll_seconds}"
done

echo "::error::web-saas-postgresql did not become running and healthy on ${MATRIX_HOST} within ${timeout_seconds}s (last state: ${last_state})." >&2
print_diagnostics
exit 1
