#!/usr/bin/env bash
set -euo pipefail

is_true() {
  [[ "${1}" == 'true' ]]
}

require_host() {
  [[ -n "${ACTION_MATRIX_HOST}" ]] || {
    echo '::error::matrix_host is required for this deployment-runner operation.' >&2
    exit 1
  }
}

resolve_host_ip() {
  require_host
  [[ -f "${ACTION_CMDB_FILE}" ]] || {
    echo "::error::CMDB file not found: ${ACTION_CMDB_FILE}" >&2
    exit 1
  }
  target_ip="$(jq -r --arg host "${ACTION_MATRIX_HOST}" '.[$host].ip // empty' "${ACTION_CMDB_FILE}")"
  [[ -n "${target_ip}" ]] || {
    echo "::error::No IP for ${ACTION_MATRIX_HOST} in ${ACTION_CMDB_FILE}" >&2
    exit 1
  }
  target_user="$(jq -r --arg host "${ACTION_MATRIX_HOST}" '.[$host].ansible_user // "root"' "${ACTION_CMDB_FILE}")"
  [[ -n "${target_user}" && "${target_user}" != "null" ]] || {
    echo "::error::No SSH user for ${ACTION_MATRIX_HOST} in ${ACTION_CMDB_FILE}" >&2
    exit 1
  }
}

configure_ssh_key() {
  [[ -n "${ACTION_SSH_KEY_B64}" ]] || {
    echo '::error::ssh_key_b64 is required when configuring SSH.' >&2
    exit 1
  }

  mkdir -p "${HOME}/.ssh"
  printf '%s' "${ACTION_SSH_KEY_B64}" | base64 -d > "${HOME}/.ssh/id_deploy"
  chmod 600 "${HOME}/.ssh/id_deploy"
  ssh-keygen -y -f "${HOME}/.ssh/id_deploy" >/dev/null
}

ssh_options=()
configure_ssh_options() {
  local connect_timeout="${1:-10}"
  ssh_options=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o "ConnectTimeout=${connect_timeout}")
  if [[ -f "${HOME}/.ssh/id_deploy" ]]; then
    ssh_options+=(-i "${HOME}/.ssh/id_deploy")
  fi
}

wait_for_ssh() {
  resolve_host_ip
  configure_ssh_options 5
  echo "Waiting for SSH to become ready on ${ACTION_MATRIX_HOST} (${target_user}@${target_ip})..."
  for _ in $(seq 1 60); do
    if ssh "${ssh_options[@]}" "${target_user}@${target_ip}" true 2>/dev/null; then
      echo "SSH is ready on ${ACTION_MATRIX_HOST} (${target_ip})."
      return
    fi
    sleep 3
  done

  echo "::error::Timed out waiting for SSH on ${ACTION_MATRIX_HOST} (${target_ip})" >&2
  exit 1
}

wait_for_package_init() {
  resolve_host_ip
  configure_ssh_options 10
  local timeout_secs="${HOST_INIT_WAIT_TIMEOUT:-120}"
  local interval_secs=3
  local privileged_shell='bash -s'
  [[ "${target_user}" == "root" ]] || privileged_shell='sudo -n bash -s'

  echo "Disabling unattended-upgrades on ${ACTION_MATRIX_HOST} (${target_ip})..."
  ssh "${ssh_options[@]}" "${target_user}@${target_ip}" "${privileged_shell}" <<'REMOTE' 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop unattended-upgrades.service >/dev/null 2>&1 || true
      systemctl disable unattended-upgrades.service >/dev/null 2>&1 || true
    fi
    pkill -f unattended-upgrade >/dev/null 2>&1 || true
REMOTE

  local probe
  probe="$(cat <<'REMOTE'
for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
  [ -e "$lock" ] || continue
  if command -v fuser >/dev/null 2>&1 && fuser "$lock" >/dev/null 2>&1; then
    echo "HELD:$lock"
    exit 1
  fi
done
if pgrep -x unattended-upgr >/dev/null 2>&1; then
  echo 'HELD:unattended-upgrades'
  exit 1
fi
echo READY
REMOTE
)"

  local deadline=$((SECONDS + timeout_secs)) last='' out=''
  while ((SECONDS < deadline)); do
    if out="$(ssh "${ssh_options[@]}" "${target_user}@${target_ip}" "${privileged_shell}" <<<"${probe}" 2>/dev/null)" && [[ "${out}" == *READY* ]]; then
      echo "Host ${ACTION_MATRIX_HOST} (${target_ip}) finished first-boot package work."
      return
    fi
    [[ "${out}" == "${last}" ]] || {
      [[ -n "${out}" ]] && echo "waiting: ${out}"
      last="${out}"
    }
    sleep "${interval_secs}"
  done

  echo "::warning::${ACTION_MATRIX_HOST} (${target_ip}) still had package locks held after ${timeout_secs}s; continuing and relying on apt lock_timeout."
}

install_ansible() {
  if command -v ansible >/dev/null 2>&1 && python3 -c 'import hvac' >/dev/null 2>&1; then
    echo 'Ansible and hvac are already available on the deployment runner.'
    return
  fi

  local pip_args=(--quiet)
  if python3 -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then
    pip_args+=(--break-system-packages)
  fi
  python3 -m pip install "${pip_args[@]}" ansible hvac
  python3 -c 'import hvac'
}

assert_ansible_target() {
  require_host
  [[ -f "${ACTION_ANSIBLE_INVENTORY}" ]] || {
    echo "::error::inventory file not found: ${ACTION_ANSIBLE_INVENTORY} (cwd=$(pwd))" >&2
    exit 1
  }

  local ping_out
  ping_out="$(ansible -i "${ACTION_ANSIBLE_INVENTORY}" "${ACTION_MATRIX_HOST}" -m ping 2>&1 || true)"
  echo "${ping_out}"
  if ! grep -q SUCCESS <<<"${ping_out}"; then
    echo "::error::Ansible target '${ACTION_MATRIX_HOST}' matched no reachable host in ${ACTION_ANSIBLE_INVENTORY}; refusing to report a no-op deploy as success." >&2
    exit 1
  fi
}

if [[ -n "${ACTION_SSH_KEY_B64}" ]]; then
  configure_ssh_key
fi
if is_true "${ACTION_WAIT_FOR_SSH}"; then
  wait_for_ssh
fi
if is_true "${ACTION_WAIT_FOR_PACKAGE_INIT}"; then
  wait_for_package_init
fi
if is_true "${ACTION_INSTALL_ANSIBLE}"; then
  install_ansible
fi
if is_true "${ACTION_ASSERT_ANSIBLE_TARGET}"; then
  assert_ansible_target
fi
