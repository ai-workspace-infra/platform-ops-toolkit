#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

cat >"${test_dir}/cmdb.json" <<'EOF'
{
  "jp-xconnect.onwalk.net": {"groups": ["agent_proxy"], "tags": ["debian"]},
  "us-xconnect.onwalk.net": {"groups": ["agent_proxy"], "tags": ["debian", "us", "spot"]},
  "hk-xconnect.onwalk.net": {"groups": ["agent_proxy"], "tags": ["debian", "hk", "ephemeral"]},
  "console-uat.onwalk.net": {"groups": ["web_saas"], "tags": ["debian"]}
}
EOF

output="${test_dir}/output"
DEPLOYMENT_ENV=uat TARGET_DOMAINS=agent-proxy GITHUB_OUTPUT="${output}" \
  bash -c "cd '${test_dir}' && '${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_build-deploy-matrix.sh'"

grep -Fq 'hosts=["console-uat.onwalk.net","jp-xconnect.onwalk.net","us-xconnect.onwalk.net"]' "${output}"
grep -Fq 'hosts_agent_proxy=["jp-xconnect.onwalk.net","us-xconnect.onwalk.net"]' "${output}"
grep -Fq 'count=3' "${output}"

echo "platform_ops_uat_hk_matrix_isolation_test: PASS"
