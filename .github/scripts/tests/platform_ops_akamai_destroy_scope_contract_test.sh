#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scope_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_assert-destroy-scope.sh"
akamai_workflow="${repo_root}/.github/workflows/akamai-cloud-iac.yml"

grep -Fq 'akamai-cloud)' "${scope_script}"
grep -Fq 'managed_resource_type="linode_instance"' "${scope_script}"
grep -Fq 'LINODE_TOKEN:?LINODE_TOKEN is required for Akamai Cloud destroy scope checks' "${scope_script}"
grep -Fq 'https://api.linode.com/v4/linode/instances?page_size=500' "${scope_script}"
grep -Fq 'PROTECTED_EXTERNAL_INSTANCE_LABELS:-observability.svc.plus' "${scope_script}"
grep -Fq 'protected migration source' "${scope_script}"
grep -Fq 'outside the selected profile manifest' "${scope_script}"
grep -Fq '.values.label // empty' "${scope_script}"
grep -Fq 'open-platform is a permanent service node' "${scope_script}"
grep -Fq 'aggregate Akamai destroy namespace' "${scope_script}"
grep -Fq 'Refusing UAT cleanup until migration, dual-end health' "${scope_script}"
grep -Fq 'state_isolation_verified == true' "${scope_script}"
grep -Fq 'terraform/uat/svc.plus/akamai-cloud/*/' "${scope_script}"
grep -Fq 'UAT Akamai requires one of the six isolated namespaces' "${akamai_workflow}"
grep -Fq 'UAT Akamai state contract requires GitOps project svc.plus' "${akamai_workflow}"
grep -Fq 'permanent UAT service namespace and cannot be destroyed' "${akamai_workflow}"
grep -Fq 'Assert safe single-namespace Akamai destroy scope' "${akamai_workflow}"

bash -n "${scope_script}"
echo "platform_ops_akamai_destroy_scope_contract: PASS"
