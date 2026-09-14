#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"
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
grep -Fq 'gateway_address=' "${deploy}"
grep -Fq '.spec.overlay.gateway_address | type == "string"' "${repo_root}/.github/scripts/xconnect-lab/validate-topology.jq"
grep -Fq 'xconnect-gateway join' "${deploy}"
grep -Fq 'deploy_xconnect_one.yml' "${deploy}"
grep -Fq "default: 'net_uat'" "${workflow}"
grep -Fq 'External Gateway identity is not bound to the requested Zero network' "${deploy}"
grep -Fq 'kv/data/CICD/domains/svc.plus tls_trust_bundle_pem_b64' "${workflow}"
grep -Fq '/etc/xconnect-gateway/ca.crt' "${deploy}"
grep -Fq 'gateway-ca.crt' "${deploy}"
grep -Fq 'system-public-ca' "${deploy}"
if grep -Fq 'openssl req -x509' "${deploy}" || grep -Fq 'XConnect disposable UAT lab CA' "${deploy}"; then
  echo 'XConnect cloud lab must consume the Vault domain certificate, not build a runner-local CA' >&2
  exit 1
fi
if grep -F 'scp "${SSH[@]}" "$LAB_DIR/bin/xconnect"' "${deploy}" | grep -Fq 'bin/xray'; then
  echo 'Linux One must obtain its managed Xray through CLI bootstrap' >&2
  exit 1
fi
grep -Fq 'xconnect_one' "${deploy}"
grep -Fq 'transport_kind:"vless-xhttp"' "${deploy}"
grep -Fq 'transport_path:"/xconnect"' "${deploy}"
grep -Fq 'xconnect_one_expected_xray_loopback_port:51830' "${deploy}"
if grep -Fq '127\\.0\\.0\\.1:18080' "${deploy}"; then
  echo "XConnect One verification must use the fixed 127.0.0.1:51830 transport loopback" >&2
  exit 1
fi
grep -Fq 'tls-trust-or-transport' "${deploy}"
grep -Fq 'CLIENT_EARLY_FAILURE_DIAGNOSTICS' "${deploy}"
grep -Fq "jq -c '[.[] | {code,healthy}]'" "${deploy}"
grep -Fq 'wireguard_handshake_age_seconds=' "${deploy}"
grep -Fq 'gateway_wireguard_handshake_age_seconds=' "${deploy}"
grep -Fq 'former peer-count window is not a valid macOS acceptance test' "${runner}"
grep -Fq 'validate-desktop' "${runner}"
grep -Fq 'desktop_ingress_cidrs' "${repo_root}/.github/scripts/xconnect-lab/prepare.py"
grep -Fq 'NODE_OBSERVATION_INPUT:' "${workflow}"
grep -Fq 'run.sh node-observation' "${workflow}"
for forbidden in mac_join_window_minutes desktop_join_window_minutes node_observation_window_minutes 'run.sh desktop' 'xconnect-desktop-public-'; do
  if grep -Fq "${forbidden}" "${workflow}"; then
    echo "Desktop/observation stage must remain outside the cloud lab workflow: ${forbidden}" >&2
    exit 1
  fi
done
grep -Fq 'xconnect-desktop-handoff-${{ github.run_id }}-${{ github.run_attempt }}' "${workflow}"
grep -Fq 'retention-days: 1' "${workflow}"
grep -Fq '$1 == peer && $2 > 0' "${deploy}"
grep -Fq 'signed-config-ack-status' "${deploy}"
grep -Fq 'probe-control-plane.py' "${workflow}"
grep -Fq 'validate-topology.jq' "${runner}"
grep -Fq 'timeout 60m bash "$ROOT/.github/scripts/xconnect-lab/node-observation.sh"' "${runner}"
grep -Fq 'xconnect-gateway status --state-dir "$state"' "${repo_root}/.github/scripts/xconnect-lab/remote-gateway-observation.sh"
grep -Fq 'systemctl enable --now xconnect-gateway-sync.timer' "${deploy}"
if grep -Fq 'xconnect-gateway up --state-dir "$state"' "${repo_root}/.github/scripts/xconnect-lab/remote-gateway-observation.sh"; then
  echo "Gateway observation must not re-apply WireGuard and reset handshakes" >&2
  exit 1
fi
grep -Fq 'timeout-minutes: 90' "${workflow}"
grep -Fq 'terraform-diagnostics.py' "${runner}"
grep -Fq 'terraform-${command}.log' "${runner}"
grep -Fq 'unset-current-credentials: true' "${workflow}"
grep -Fq 'steps.prepare.outcome == '\''success'\''' "${workflow}"
grep -Fq "if: inputs.mode == 'cleanup' && steps.prepare.outcome == 'success'" "${workflow}"
grep -Fq "if: inputs.mode == 'cleanup'" "${workflow}"
if grep -Fq 'Always destroy only this lab state' "${workflow}"; then
  echo 'Apply runs must retain the one-hour lab lease; cleanup must be explicit.' >&2
  exit 1
fi
for stage in setup bootstrap gateway one verify; do
  grep -Fq "run.sh ${stage}" "${workflow}"
done
grep -Fq 'gateway_release_tag:$gateway' "${repo_root}/.github/scripts/xconnect-lab/lease.sh"
grep -Fq 'wireguard-handshake' "${repo_root}/gitops/vpn-overlay/uat/xconnect-lab.json" 2>/dev/null || true

if grep -Fq 'xconnect-zero-lab-linux-arm64' "${runner}" || grep -Fq 'xconnect-lab-zero.service' "${deploy}"; then
  echo "Formal UAT lab must not download or run the experimental Zero controller" >&2
  exit 1
fi

echo "xconnect_formal_uat_lab_contract_test: PASS"
