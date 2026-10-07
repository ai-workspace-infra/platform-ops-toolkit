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
grep -Fq '/api/internal/overlay/gateways/reconcile-stable-owner' "${deploy}"
grep -Fq 'Stable UAT Gateway ownership reconciliation passed' "${deploy}"
grep -Fq 'environment:"uat",network_id:"net_uat",gateway_id:"gw-uat-tw-xconnect"' "${deploy}"
if grep -Fq 'current_gateway_endpoint_host' "${deploy}"; then
  echo 'historical Gateway endpoint input must not be sent by the lab' >&2
  exit 1
fi
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
grep -Eq 'uses: ai-workspace-infra/playbooks/\.github/actions/xconnect-node-observation@[0-9a-f]{40}' "${workflow}"
grep -Fq 'window: ${{ env.NODE_OBSERVATION_WINDOW_MINUTES }}' "${workflow}"
if grep -Fq 'run.sh node-observation' "${workflow}"; then
  echo 'Node execution must use the fixed owner action, not the legacy wrapper' >&2
  exit 1
fi
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
grep -Fq 'operation: xconnect-control-plane' "${workflow}"
grep -Fq 'XCONNECT_DECLARATION_JSON:' "${workflow}"
grep -Eq 'uses: ai-workspace-infra/playbooks/\.github/actions/service-probes@[0-9a-f]{40}' "${workflow}"
grep -Fq 'validate-topology.jq' "${runner}"
grep -Fq 'timeout 60m bash "$ROOT/.github/scripts/xconnect-lab/node-observation.sh"' "${runner}"
grep -Fq 'xconnect-gateway status --state-dir "$state"' "${repo_root}/.github/scripts/xconnect-lab/remote-gateway-observation.sh"
grep -Fq 'systemctl enable --now xconnect-gateway-sync.timer' "${deploy}"
if grep -Fq 'xconnect-gateway up --state-dir "$state"' "${repo_root}/.github/scripts/xconnect-lab/remote-gateway-observation.sh"; then
  echo "Gateway observation must not re-apply WireGuard and reset handshakes" >&2
  exit 1
fi
grep -Fq 'timeout-minutes: 90' "${workflow}"
grep -Fq "default: '9570b01959396e1d0e20331205b5cb5718f5c588'" "${workflow}"
grep -Fq 'uses: ./iac_modules/.github/actions/xconnect-lab-lifecycle' "${workflow}"
for stage in preflight prepare apply cleanup; do
  grep -Fq "operation: ${stage}" "${workflow}"
done
for retired_call in 'run.sh preflight' 'run.sh prepare' 'run.sh apply' 'run.sh cleanup'; do
  if grep -Fq "$retired_call" "${workflow}"; then
    echo "Terraform/state stage still calls the frozen mixed Toolkit runner: $retired_call" >&2
    exit 1
  fi
done
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
# These host/service callers remain frozen until H1-H6 in the execution
# contract have both an owner caller and same-run UAT receipts. Keeping this
# assertion prevents a scanner-only cleanup from silently dropping coverage.
grep -Fq 'bash .github/scripts/xconnect-existing-one-uat/deploy.sh' "${workflow}"
grep -Fq 'bash .github/scripts/xconnect-lab/enroll-node.sh' "${workflow}"
gates="${repo_root}/docs/agent/2026-10-05-next-execution-batches-contract.md"
for gate in H1 H2 H3 H4 H5 H6; do
  grep -Fq "| ${gate} " "${gates}"
done
grep -Fq 'gateway_release_tag:$gateway' "${repo_root}/.github/scripts/xconnect-lab/lease.sh"
if [[ -n "${XCONNECT_GITOPS_ROOT:-}" ]]; then
  declaration="${XCONNECT_GITOPS_ROOT}/vpn-overlay/uat/xconnect-lab.json"
  test -f "${declaration}" || {
    echo "fixed-SHA XConnect declaration fixture is missing: ${declaration}" >&2
    exit 1
  }
  if [[ -n "${XCONNECT_GITOPS_REF:-}" ]]; then
    actual_ref="$(git -C "${XCONNECT_GITOPS_ROOT}" rev-parse HEAD)"
    [[ "${actual_ref}" == "${XCONNECT_GITOPS_REF}" ]] || {
      echo "XConnect declaration fixture is not checked out at ${XCONNECT_GITOPS_REF}" >&2
      exit 1
    }
  fi
  jq -e '
    .kind == "XConnectLabTopology" and
    .metadata.environment == "uat" and
    .spec.gateway_transport.transport == "vless-xhttp" and
    .spec.gateway_transport.profile.path == "/xconnect" and
    .spec.gateway_transport.profile.host == "tw-xconnect.svc.plus" and
    .spec.node_observation.mode == "until-expiry"
  ' "${declaration}" >/dev/null
fi

if grep -Fq 'xconnect-zero-lab-linux-arm64' "${runner}" || grep -Fq 'xconnect-lab-zero.service' "${deploy}"; then
  echo "Formal UAT lab must not download or run the experimental Zero controller" >&2
  exit 1
fi

echo "xconnect_formal_uat_lab_contract_test: PASS"
