#!/usr/bin/env bash
set -euo pipefail

: "${CMDB_FILE:?CMDB_FILE is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

if [[ ! -s "${CMDB_FILE}" ]]; then
  echo "::error::CMDB file is empty: ${CMDB_FILE}" >&2
  exit 1
fi

mapfile -t agent_ips < <(
  jq -r '
    to_entries[]
    | select((.value.groups // []) | index("agent_proxy"))
    | (.value.ip // .value.ansible_host // empty)
    | select(test("^[0-9a-fA-F:.]+$"))
  ' "${CMDB_FILE}"
)

if ((${#agent_ips[@]} == 0)); then
  echo "No agent-proxy host is present in ${CMDB_FILE}; Billing Caddy ingress stays disabled."
  echo "WEB_SAAS_BILLING_ALLOWED_CIDRS=" >> "${GITHUB_ENV}"
  exit 0
fi

cidrs=()
for ip in "${agent_ips[@]}"; do
  if [[ "${ip}" == *:* ]]; then
    cidrs+=("[${ip}]/128")
  else
    cidrs+=("${ip}/32")
  fi
done

allowed_cidrs="$(IFS=' '; echo "${cidrs[*]}")"
echo "WEB_SAAS_BILLING_ALLOWED_CIDRS=${allowed_cidrs}" >> "${GITHUB_ENV}"
echo "Billing Caddy ingress will allow agent-proxy CIDRs: ${allowed_cidrs}"
