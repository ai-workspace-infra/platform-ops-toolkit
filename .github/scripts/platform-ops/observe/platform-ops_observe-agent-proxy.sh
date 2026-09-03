#!/usr/bin/env bash
set -euo pipefail

# Final Agent Proxy gate. This runs after DNS reconciliation/cutover, so the
# agent can reach its controller using the normal public TLS route. The deploy
# job intentionally installs the agent without using this gate as a pre-DNS
# blocker.

cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
timeout_seconds="${AGENT_PROXY_READY_TIMEOUT_SECONDS:-180}"
poll_seconds="${AGENT_PROXY_READY_POLL_SECONDS:-5}"

[[ -f "${cmdb_file}" ]] || {
  echo "::error::CMDB file not found: ${cmdb_file}" >&2
  exit 2
}
[[ "${timeout_seconds}" =~ ^[0-9]+$ && "${poll_seconds}" =~ ^[0-9]+$ ]] || {
  echo "::error::Agent Proxy readiness timeout and poll interval must be integers." >&2
  exit 2
}

if [[ -n "${MATRIX_HOST:-}" ]]; then
  mapfile -t agent_hosts < <(
    jq -r --arg host "${MATRIX_HOST}" '[to_entries[] | select(.key == $host and (.value.groups // [] | contains(["agent_proxy"]))) | [.key, .value.ip, (.value.ansible_user // "root")] | @tsv] | .[]' "${cmdb_file}"
  )
else
  mapfile -t agent_hosts < <(
    jq -r '[to_entries[] | select(.value.groups // [] | contains(["agent_proxy"])) | [.key, .value.ip, (.value.ansible_user // "root")] | @tsv] | .[]' "${cmdb_file}"
  )
fi

if [[ "${#agent_hosts[@]}" -eq 0 ]]; then
  echo "No Agent Proxy hosts are present in ${cmdb_file}; skipping final gate."
  exit 0
fi

ssh_opts=(
  -i ~/.ssh/id_deploy
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=no
)

check_host() {
  local host_name="$1"
  local host_ip="$2"
  local host_user="$3"
  local remote_shell='bash -s'
  [[ "${host_user}" == "root" ]] || remote_shell='sudo -n bash -s'

  ssh "${ssh_opts[@]}" "${host_user}@${host_ip}" "${remote_shell}" <<'REMOTE'
set -u
services=(caddy agent-proxy xray xray-tcp xray-exporter-xhttp xray-exporter-tcp)
files=(/usr/local/etc/xray/config.json /usr/local/etc/xray/tcp-config.json)

for file in "${files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    echo "runtime_config=${file} state=missing-or-empty"
    exit 1
  fi
done

# The deploy stage deliberately does not start Xray before DNS cutover. Once
# the controller is reachable through the real DNS route, the final gate owns
# this last convergence step before checking the complete service set.
systemctl start xray.service xray-tcp.service

for service in "${services[@]}"; do
  state="$(systemctl is-active "${service}" 2>/dev/null || true)"
  if [[ "${state}" != "active" ]]; then
    echo "service=${service} state=${state:-unknown}"
    exit 1
  fi
done
REMOTE
}

diagnose_host() {
  local host_name="$1"
  local host_ip="$2"
  local host_user="$3"
  local remote_shell='bash -s'
  [[ "${host_user}" == "root" ]] || remote_shell='sudo -n bash -s'

  echo "::group::Agent Proxy diagnostics for ${host_name} (${host_ip})"
  ssh "${ssh_opts[@]}" "${host_user}@${host_ip}" "${remote_shell}" <<'REMOTE' 2>&1 | sed -E \
    -e 's/Bearer[[:space:]]+[^[:space:]]+/Bearer ***REDACTED***/g' \
    -e 's/gh[pousr]_[A-Za-z0-9_]+/***REDACTED_GITHUB_TOKEN***/g' \
    -e 's/hvs\.[A-Za-z0-9]+/***REDACTED_VAULT_TOKEN***/g'
    set +e
    echo "--- service states ---"
    systemctl is-active caddy agent-proxy xray xray-tcp xray-exporter-xhttp xray-exporter-tcp 2>&1 || true
    echo "--- agent service status ---"
    systemctl status agent-proxy --no-pager -l 2>&1 || true
    echo "--- agent service journal ---"
    journalctl -u agent-proxy -n 120 --no-pager 2>&1 || true
    echo "--- runtime config files ---"
    ls -l /usr/local/etc/xray/config.json /usr/local/etc/xray/tcp-config.json 2>&1 || true
REMOTE
  echo "::endgroup::"
}

for host_entry in "${agent_hosts[@]}"; do
  IFS=$'\t' read -r host_name host_ip host_user <<< "${host_entry}"
  [[ -n "${host_name}" && -n "${host_ip}" && -n "${host_user}" ]] || continue

  deadline=$(( $(date +%s) + timeout_seconds ))
  last_failure=""
  while :; do
    if failure="$(check_host "${host_name}" "${host_ip}" "${host_user}" 2>&1)"; then
      echo "Agent Proxy final readiness passed for ${host_name} (${host_ip})."
      break
    fi
    last_failure="${failure}"
    if [[ $(date +%s) -ge ${deadline} ]]; then
      echo "::error::Agent Proxy ${host_name} did not become ready after DNS reconciliation within ${timeout_seconds}s." >&2
      echo "Last check: ${last_failure}" >&2
      diagnose_host "${host_name}" "${host_ip}" "${host_user}"
      exit 1
    fi
    sleep "${poll_seconds}"
  done
done
