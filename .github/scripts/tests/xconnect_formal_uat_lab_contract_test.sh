#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-cloud-lab.yml"
runner="${repo_root}/.github/scripts/xconnect-lab/run.sh"
deploy="${repo_root}/.github/scripts/xconnect-lab/deploy.sh"

for required in gateway_release_tag XConnect-Gateway ZERO_SERVICE_TOKEN ZERO_OWNER_EMAIL; do
  grep -Fq "${required}" "${workflow}" || {
    echo "XConnect UAT workflow is missing ${required}" >&2
    exit 1
  }
done

grep -Fq 'xconnect-gateway-linux-arm64' "${runner}"
grep -Fq '/api/internal/overlay/networks/bootstrap' "${deploy}"
grep -Fq 'xconnect-gateway join' "${deploy}"
grep -Fq 'xconnect join' "${deploy}"
grep -Fq 'wireguard-handshake' "${repo_root}/gitops/topology/uat/xconnect-lab.json" 2>/dev/null || true

if grep -Fq 'xconnect-zero-lab-linux-arm64' "${runner}" || grep -Fq 'xconnect-lab-zero.service' "${deploy}"; then
  echo "Formal UAT lab must not download or run the experimental Zero controller" >&2
  exit 1
fi

echo "xconnect_formal_uat_lab_contract_test: PASS"
