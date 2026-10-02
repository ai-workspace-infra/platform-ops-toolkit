#!/usr/bin/env bash
set -euo pipefail

# The DNS script's own scope contract is tested next to the script, in
# playbooks/scripts/pipeline/tests/switch_cloudflare_dns_scope_test.sh.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"

grep -Fq 'playbooks/scripts/pipeline/switch-cloudflare-dns-records.sh' "${workflow}"
grep -Fq 'deployment_env == '"'"'uat'"'"'' "${workflow}"

echo "prod_agent_proxy_dns_scope_test: PASS"
