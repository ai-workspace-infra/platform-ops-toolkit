#!/usr/bin/env bash
set -eo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env PLAYBOOK_NAME

INVENTORY="${INVENTORY_FILE:-../cmdb/inventory.ini}"
EXTRA_CMD_ARGS=()

if [ -n "${MATRIX_HOST:-}" ]; then
  EXTRA_CMD_ARGS+=("--limit" "${MATRIX_HOST}")
fi

if [ -n "${JSON_VARS:-}" ]; then
  VARS_TMP=$(mktemp /tmp/ansible-vars-XXXXXX.json)
  echo "${JSON_VARS}" > "${VARS_TMP}"
  EXTRA_CMD_ARGS+=("-e" "@${VARS_TMP}")
  trap 'rm -f "${VARS_TMP}"' EXIT
fi

if [ $# -gt 0 ]; then
  EXTRA_CMD_ARGS+=("$@")
fi

exec ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_NAME}" "${EXTRA_CMD_ARGS[@]}"
