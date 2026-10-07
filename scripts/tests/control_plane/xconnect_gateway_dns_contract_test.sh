#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"

python3 - "${workflow}" <<'PY'
import re
import sys
from pathlib import Path

import yaml

workflow_path = Path(sys.argv[1])
document = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
triggers = document.get("on", document.get(True))
inputs = triggers["workflow_dispatch"]["inputs"]
iac_ref = inputs["iac_ref"]["default"]
if not re.fullmatch(r"[0-9a-f]{40}", iac_ref):
    raise SystemExit("iac_ref default must be an immutable commit SHA")
if inputs["gateway_release_tag"]["default"] != "v0.1.8":
    raise SystemExit("Gateway release default must match the reviewed UAT declaration")

apply_job = document["jobs"]["apply"]
expected_ref = "${{ inputs.iac_ref || '" + iac_ref + "' }}"
if apply_job["env"].get("IAC_REF") != expected_ref:
    raise SystemExit("apply job must derive IAC_REF from the reviewed default with an explicit override")

steps = apply_job["steps"]
checkout_index = next(
    index for index, step in enumerate(steps)
    if step.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules"
)
checkout = steps[checkout_index]
if checkout["with"].get("ref") != "${{ env.IAC_REF }}":
    raise SystemExit("IaC owner checkout must use the validated IAC_REF")
if checkout["with"].get("path") != "iac_modules":
    raise SystemExit("IaC owner checkout must populate the iac_modules caller path")

dns_index = next(
    index for index, step in enumerate(steps)
    if step.get("name") == "Reconcile stable Gateway DNS in Cloudflare"
)
dns = steps[dns_index]
if checkout_index >= dns_index:
    raise SystemExit("Gateway DNS must run after the fixed-SHA IaC owner checkout")
if dns.get("if") != "inputs.mode == 'apply' && inputs.gateway_provider == 'external'":
    raise SystemExit("Gateway DNS caller must stay apply-only and external-Gateway-only")
if dns.get("run") != "python3 iac_modules/scripts/pipeline/cloudflare-gateway-dns-upsert.py":
    raise SystemExit("Gateway DNS caller must execute the checked-out IaC owner implementation")
expected_env = {
    "DNS_ENVIRONMENT": "uat",
    "DNS_ZONE": "svc.plus",
    "DNS_RECORD_NAME": "${{ env.EXTERNAL_GATEWAY_SERVER_NAME }}",
    "DNS_TARGET_IP": "${{ env.EXTERNAL_GATEWAY_HOST }}",
    "DNS_CHECKPOINT_PATH": "${{ runner.temp }}/xconnect-gateway-dns-checkpoint.json",
}
for key, value in expected_env.items():
    if dns.get("env", {}).get(key) != value:
        raise SystemExit(f"Gateway DNS caller has an invalid {key} contract")
PY

if grep -Fq '.github/scripts/xconnect-lab/reconcile-gateway-dns.sh' "${workflow}"; then
  echo 'Gateway DNS caller must use the merged iac_modules owner' >&2
  exit 1
fi
if grep -Eq 'CLOUDFLARE_(API_TOKEN|ACCOUNT_ID).*GitOps|gitops.*CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)' "${workflow}"; then
  echo 'Cloudflare credentials must remain Vault-injected, not GitOps data' >&2
  exit 1
fi

echo 'xconnect_gateway_dns_contract_test: PASS'
