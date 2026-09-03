#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
restore_script="${repo_root}/.github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh"
observe_script="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_observe-agent-proxy.sh"
runner_script="${repo_root}/.github/actions/setup-deployment-runner/scripts/setup.sh"

for script in "${restore_script}" "${observe_script}"; do
  grep -Fq '.ansible_user // "root"' "${script}"
  grep -Fq 'sudo -n' "${script}"
done

grep -Fq "privileged_shell='sudo -n bash -s'" "${runner_script}"

if grep -Eq 'host="root@|"root@\$\{host_ip\}"' "${restore_script}" "${observe_script}"; then
  echo 'AWS selfhost scripts must use the CMDB SSH user instead of a hard-coded root login.' >&2
  exit 1
fi

echo 'aws_selfhost_rootless_ssh_test: PASS'
