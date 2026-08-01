#!/usr/bin/env bash
set -euo pipefail

: "${CMDB_FILE:?CMDB_FILE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

controller_ip="$(jq -r '
  [to_entries[]
   | select((.value.groups // []) | index("web_saas"))
   | .value.ip // empty]
  | first // empty
' "${CMDB_FILE}")"

if [[ -z "${controller_ip}" ]]; then
  echo "::error::CMDB has no web_saas host IP; cannot bootstrap agent-proxy before DNS cutover." >&2
  exit 1
fi

echo "Resolved agent controller IP from current CMDB: ${controller_ip}"
echo "ip=${controller_ip}" >> "${GITHUB_OUTPUT}"
