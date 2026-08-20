#!/usr/bin/env bash
set -euo pipefail

: "${CMDB_FILE:?CMDB_FILE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

controller_ip=""
if [[ -n "${AGENT_CONTROLLER_URL:-}" ]]; then
  controller_host="${AGENT_CONTROLLER_URL#https://}"
  controller_host="${controller_host%%/*}"
  controller_ip="$(getent ahostsv4 "${controller_host}" | awk 'NR == 1 { print $1; exit }')"
  if [[ -n "${controller_ip}" ]]; then
    echo "Resolved Agent Proxy controller ${controller_host} via public DNS: ${controller_ip}"
  fi
fi

# Keep the existing CMDB path for standalone Selfhost Web SaaS deployments,
# where the controller is the current web_saas host and DNS may intentionally
# still point at a different canonical target during a cutover.
if [[ -z "${controller_ip}" ]]; then
  controller_ip="$(jq -r '
    [to_entries[]
     | select((.value.groups // []) | index("web_saas"))
     | .value.ip // empty]
    | first // empty
  ' "${CMDB_FILE}")"
fi

if [[ -z "${controller_ip}" ]]; then
  echo "::error::CMDB has no web_saas host IP; cannot bootstrap agent-proxy before DNS cutover." >&2
  exit 1
fi

echo "Resolved agent controller IP from current CMDB: ${controller_ip}"
echo "ip=${controller_ip}" >> "${GITHUB_OUTPUT}"
