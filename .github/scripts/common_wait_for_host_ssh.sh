#!/bin/bash
set -eo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env MATRIX_HOST
ip="$(jq -r --arg host "$MATRIX_HOST" '.[$host].ip' cmdb/cmdb.json)"
ssh_key="${SSH_KEY_PATH:-$HOME/.ssh/id_deploy}"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5)
if [ -f "${ssh_key}" ]; then
  ssh_opts+=(-i "${ssh_key}")
fi

echo "Waiting for SSH to become ready on ${MATRIX_HOST} (${ip})..."
for i in $(seq 1 60); do
  if ssh "${ssh_opts[@]}" "root@${ip}" "true" 2>/dev/null; then
    echo "SSH is ready on ${MATRIX_HOST} (${ip})."
    exit 0
  fi
  sleep 3
done

echo "::error::Timed out waiting for SSH on ${MATRIX_HOST} (${ip})" >&2
exit 1
