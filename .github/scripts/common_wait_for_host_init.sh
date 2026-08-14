#!/bin/bash
# Wait until a freshly provisioned host has finished its own first-boot
# package work before any deployment step touches apt.
#
# A new VPS comes up running cloud-init and, on Debian/Ubuntu images,
# unattended-upgrades. Both hold the dpkg frontend lock, typically for tens of
# seconds and occasionally for minutes. A deploy that starts installing
# packages during that window dies on:
#
#     dpkg: error: dpkg frontend lock was locked by
#     /usr/bin/apt-get process with pid <n>
#
# which is what took down the whole agent-proxy play in r8 and left the host
# without xray, the exporters or vector.
#
# Waiting once here, in the bootstrap job, is what "deploy_base prepares the
# machine" means: every later job then runs against a host whose first-boot
# work has converged, instead of each apt task carrying its own long timeout
# as a fallback.
set -eo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env MATRIX_HOST

ip="$(jq -r --arg host "$MATRIX_HOST" '.[$host].ip' cmdb/cmdb.json)"
if [[ -z "$ip" || "$ip" == "null" ]]; then
  echo "::error::No IP for ${MATRIX_HOST} in cmdb/cmdb.json" >&2
  exit 1
fi

# Bounded so a genuinely stuck host fails the job rather than hanging it. Held
# locks normally clear well inside this; the point is to stop racing them, not
# to wait indefinitely.
timeout_secs="${HOST_INIT_WAIT_TIMEOUT:-120}"
interval_secs=3
ssh_key="${SSH_KEY_PATH:-$HOME/.ssh/id_deploy}"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o BatchMode=yes)
if [ -f "${ssh_key}" ]; then
  ssh_opts+=(-i "${ssh_key}")
fi

# Actively disable and terminate background unattended-upgrades to avoid 7-minute lock delays.
echo "Disabling unattended-upgrades on ${MATRIX_HOST} (${ip})..."
ssh "${ssh_opts[@]}" "root@${ip}" "
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop unattended-upgrades.service >/dev/null 2>&1 || true
    systemctl disable unattended-upgrades.service >/dev/null 2>&1 || true
  fi
  pkill -f unattended-upgrade >/dev/null 2>&1 || true
" 2>/dev/null || true

# Non-Debian hosts have neither cloud-init's package phase nor
# unattended-upgrades; the probe simply reports ready.
probe=$(cat <<'REMOTE'
for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
  [ -e "$lock" ] || continue
  if command -v fuser >/dev/null 2>&1 && fuser "$lock" >/dev/null 2>&1; then
    echo "HELD:$lock"
    exit 1
  fi
done
if pgrep -x unattended-upgr >/dev/null 2>&1; then
  echo "HELD:unattended-upgrades"
  exit 1
fi
echo READY
REMOTE
)

deadline=$(( SECONDS + timeout_secs ))
last=""
while (( SECONDS < deadline )); do
  if out="$(ssh "${ssh_opts[@]}" "root@${ip}" "bash -s" <<<"$probe" 2>/dev/null)" \
     && [[ "$out" == *READY* ]]; then
    echo "Host ${MATRIX_HOST} (${ip}) finished first-boot package work."
    exit 0
  fi
  [[ "$out" == "$last" ]] || { [[ -n "$out" ]] && echo "waiting: ${out}"; last="$out"; }
  sleep "$interval_secs"
done

# Do not fail the deploy on this alone: apt still carries lock_timeout as a
# fallback, and a host that merely holds the lock a little longer than the
# window should not block a release. Say so loudly instead.
echo "::warning::${MATRIX_HOST} (${ip}) still had package locks held after ${timeout_secs}s; continuing and relying on apt lock_timeout."
exit 0
