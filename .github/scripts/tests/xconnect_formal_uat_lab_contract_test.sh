#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-cloud-lab.yml"
runner="${repo_root}/.github/scripts/xconnect-lab/run.sh"
deploy="${repo_root}/.github/scripts/xconnect-lab/deploy.sh"

for required in gateway_release_tag XConnect-Gateway ZERO_SERVICE_TOKEN ZERO_OWNER_EMAIL mac_join_window_minutes desktop_join_window_minutes node_observation_window_minutes; do
  grep -Fq "${required}" "${workflow}" || {
    echo "XConnect UAT workflow is missing ${required}" >&2
    exit 1
  }
done

grep -Fq 'xconnect-gateway-linux-arm64' "${runner}"
grep -Fq '/api/internal/overlay/networks/bootstrap' "${deploy}"
grep -Fq 'gateway_address=$(jq -er .spec.overlay.gateway_address "$DECL")' "${deploy}"
grep -Fq '.spec.overlay.gateway_address == "10.77.0.1/32"' "${repo_root}/.github/scripts/xconnect-lab/validate-topology.jq"
grep -Fq 'xconnect-gateway join' "${deploy}"
grep -Fq 'xconnect join' "${deploy}"
grep -Fq 'tls-trust-or-transport' "${deploy}"
grep -Fq "jq -c '[.[] | {code,healthy}]'" "${deploy}"
grep -Fq 'wireguard_handshake_age_seconds=' "${deploy}"
grep -Fq 'gateway_wireguard_handshake_age_seconds=' "${deploy}"
grep -Fq 'former peer-count window is not a valid macOS acceptance test' "${runner}"
grep -Fq 'validate-desktop' "${runner}"
grep -Fq 'desktop_ingress_cidrs' "${repo_root}/.github/scripts/xconnect-lab/prepare.py"
grep -Fq 'PUBLIC_DESKTOP_HANDOFF_READY' "${deploy}"
grep -Fq 'peer-handshake-observation-only=true' "${repo_root}/.github/scripts/xconnect-lab/desktop.sh"
grep -Fq 'NODE_OBSERVATION_RESULT=SUMMARY_ONLY' "${repo_root}/.github/scripts/xconnect-lab/node-observation.sh"
grep -Fq 'mutually exclusive' "${runner}"
grep -Fq '$1 == peer && $2 > 0' "${deploy}"
grep -Fq 'signed-config-ack-status' "${deploy}"
grep -Fq 'probe-control-plane.py' "${workflow}"
grep -Fq 'validate-topology.jq' "${runner}"
grep -Fq 'timeout 120m bash "$ROOT/.github/scripts/xconnect-lab/node-observation.sh"' "${runner}"
grep -Fq 'unset-current-credentials: true' "${workflow}"
grep -Fq 'steps.prepare.outcome == '\''success'\''' "${workflow}"
for stage in setup bootstrap gateway one verify; do
  grep -Fq "run.sh ${stage}" "${workflow}"
done
grep -Fq 'upload-artifact@v4' "${workflow}"
grep -Fq 'retention-days: 1' "${workflow}"
grep -Fq 'run.sh desktop' "${workflow}"
grep -Fq 'run.sh node-observation' "${workflow}"
grep -Fq 'gateway_release_tag:$gateway' "${repo_root}/.github/scripts/xconnect-lab/lease.sh"
grep -Fq 'wireguard-handshake' "${repo_root}/gitops/vpn-overlay/uat/xconnect-lab.json" 2>/dev/null || true

if grep -Fq 'xconnect-zero-lab-linux-arm64' "${runner}" || grep -Fq 'xconnect-lab-zero.service' "${deploy}"; then
  echo "Formal UAT lab must not download or run the experimental Zero controller" >&2
  exit 1
fi

echo "xconnect_formal_uat_lab_contract_test: PASS"
