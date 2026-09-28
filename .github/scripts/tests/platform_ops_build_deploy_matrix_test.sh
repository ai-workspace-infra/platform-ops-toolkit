#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/cmdb.json" <<'JSON'
{
  "environment": "uat",
  "project_id": "open-platform-prod",
  "cloud_run_uri": "https://open-platform-uat.example.run.app",
  "vault_nodes": [{"name": "vault-uat-0", "private_ip": "10.60.0.2"}],
  "web-saas-uat": {
    "ip": "192.0.2.10",
    "ansible_user": "ubuntu",
    "groups": ["web_saas"]
  },
  "agent-proxy-jp-uat": {
    "ip": "192.0.2.11",
    "ansible_user": "ubuntu",
    "groups": ["agent_proxy"]
  }
}
JSON

output_file="${workdir}/github-output"
(cd "${workdir}" && GITHUB_OUTPUT="${output_file}" bash "${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_build-deploy-matrix.sh")

grep -Fxq 'hosts=["web-saas-uat","agent-proxy-jp-uat"]' "${output_file}"
grep -Fxq 'hosts_web_saas=["web-saas-uat"]' "${output_file}"
grep -Fxq 'hosts_agent_proxy=["agent-proxy-jp-uat"]' "${output_file}"
grep -Fxq 'count=2' "${output_file}"

echo "platform_ops_build_deploy_matrix: PASS"
