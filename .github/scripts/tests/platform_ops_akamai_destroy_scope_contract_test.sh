#!/usr/bin/env bash
set -euo pipefail

# The destroy-scope guard itself is tested next to the script, in
# iac_modules/scripts/pipeline/tests/. This keeps the Akamai pipeline calling it.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
akamai_workflow="${repo_root}/.github/workflows/akamai-cloud-iac.yml"

grep -Fq 'UAT Akamai requires one of the six isolated namespaces' "${akamai_workflow}"
grep -Fq 'UAT Akamai state contract requires GitOps project svc.plus' "${akamai_workflow}"
if grep -Fq 'permanent UAT service namespace and cannot be destroyed' "${akamai_workflow}"; then
  echo 'open-platform destroy must be guarded by the scope acceptance contract, not rejected at input validation' >&2
  exit 1
fi
grep -Fq 'Assert safe single-namespace Akamai destroy scope' "${akamai_workflow}"
grep -Fq 'iac_modules/scripts/pipeline/assert-destroy-scope.sh' "${akamai_workflow}"

echo "platform_ops_akamai_destroy_scope_contract: PASS"
