#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
deployer="${repo_root}/scripts/serverless_uat/deploy_portal_opennext_worker.sh"

grep -Fq '.spec.serverless.accounts_host' "${deployer}"
grep -Fq 'ACCOUNT_SERVICE_URL="https://${accounts_host}"' "${deployer}"
grep -Fq 'ACCOUNT_SERVICE_URL="${ACCOUNT_SERVICE_URL}"' "${deployer}"
grep -Fq '.vars = ((.vars // {}) + {ACCOUNT_SERVICE_URL: $account_service_url})' "${deployer}"
grep -Fq 'Next/OpenNext does not inherit the' "${deployer}"

if grep -Fq 'ACCOUNT_SERVICE_URL="https://accounts.svc.plus"' "${deployer}"; then
  echo "Portal deploy must not hard-code the canonical self-host Accounts URL" >&2
  exit 1
fi

echo "serverless_portal_accounts_endpoint_contract_test: PASS"
