#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scope_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_assert-destroy-scope.sh"

grep -Fq 'akamai-cloud)' "${scope_script}"
grep -Fq 'managed_resource_type="linode_instance"' "${scope_script}"
grep -Fq 'LINODE_TOKEN:?LINODE_TOKEN is required for Akamai Cloud destroy scope checks' "${scope_script}"
grep -Fq 'https://api.linode.com/v4/linode/instances?page_size=500' "${scope_script}"

bash -n "${scope_script}"
echo "platform_ops_akamai_destroy_scope_contract: PASS"
