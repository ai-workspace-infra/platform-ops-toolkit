#!/usr/bin/env bash
# Web SaaS host scripts log in as the CMDB SSH user. GCP OS Login (and AWS)
# hosts reject root; their user has passwordless sudo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scripts=(
  .github/scripts/platform-ops/observe/platform-ops_observe-web-saas-ingress.sh
  .github/scripts/platform-ops/observe/platform-ops_observe-web-saas-containers.sh
)
for script in "${scripts[@]}"; do
  grep -Fq 'lib/cmdb-ssh-login.sh' "${repo_root}/${script}" || { echo "${script} must resolve the CMDB SSH user" >&2; exit 1; }
  if grep -Fq 'root@' "${repo_root}/${script}"; then
    echo "${script} must not hard-code a root login" >&2
    exit 1
  fi
done

echo 'web_saas_rootless_ssh_test: PASS'
