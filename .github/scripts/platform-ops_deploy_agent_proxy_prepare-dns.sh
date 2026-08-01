#!/usr/bin/env bash
set -euo pipefail

: "${CMDB_FILE:?CMDB_FILE is required}"
: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${TARGET_DOMAIN_BASE:?TARGET_DOMAIN_BASE is required}"
: "${CLOUDFLARE_DNS_API_TOKEN:?CLOUDFLARE_DNS_API_TOKEN is required}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agent_proxy_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${CMDB_FILE}")"
[[ -n "${agent_proxy_ip}" ]] || {
  echo "::error::CMDB has no IP for ${MATRIX_HOST}; refusing to prepare agent-proxy DNS." >&2
  exit 1
}

agent_proxy_domain="agent-proxy.${TARGET_DOMAIN_BASE}"
echo "Preparing ${agent_proxy_domain} -> ${agent_proxy_ip} before Caddy ACME issuance."

(
  cd "${repo_root}/playbooks"
  TARGET_DOMAIN_BASE="${TARGET_DOMAIN_BASE}" \
    AGENT_PROXY_IP="${agent_proxy_ip}" \
    CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN}" \
    ansible-playbook -i localhost, prepare-agent-proxy-dns.yml
)

for attempt in {1..30}; do
  resolved_ips="$(dig +short "${agent_proxy_domain}" @1.1.1.1 | sort -u || true)"
  if grep -Fxq "${agent_proxy_ip}" <<<"${resolved_ips}"; then
    echo "Confirmed public DNS for ${agent_proxy_domain}: ${agent_proxy_ip}"
    exit 0
  fi
  echo "Waiting for public DNS propagation (${attempt}/30): ${agent_proxy_domain} -> ${agent_proxy_ip}"
  sleep 2
done

echo "::error::Public DNS for ${agent_proxy_domain} did not resolve to ${agent_proxy_ip} after 60 seconds." >&2
exit 1
