#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
dns_script="${repo_root}/.github/scripts/platform-ops/dns/platform-ops_switch_dns_switch-cloudflare-dns-records.sh"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

# Agent Proxy production cutover must publish only its dedicated selfhost
# endpoint; the shared agent-proxy.svc.plus endpoint remains unmanaged here.
grep -Fq 'TARGET_DOMAINS:-}" = "agent-proxy"' "${dns_script}"
grep -Fq '"cloudflare_dns_source_hosts": ["agent_proxy"]' "${dns_script}"
grep -Fq '"cloudflare_dns_static_records": []' "${dns_script}"
grep -Fq '"cloudflare_dns_alias_records\":${DNS_ALIAS_RECORDS_JSON}' "${dns_script}"
grep -Fq 'deployment_env == '\''uat'\''' "${workflow}"

echo "prod_agent_proxy_dns_scope_test: PASS"
