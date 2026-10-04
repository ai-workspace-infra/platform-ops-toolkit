#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="$repo_root/.github/workflows/xconnect-zero-cloud.yaml"
runner="$repo_root/.github/scripts/xconnect-lab/node-observation.sh"
gateway_fragment="$repo_root/.github/scripts/xconnect-lab/remote-gateway-observation.sh"
client_fragment="$repo_root/.github/scripts/xconnect-lab/remote-client-observation.sh"

test -x "$runner"
test -f "$gateway_fragment"
test -f "$client_fragment"
grep -Fq '1308c585bbb3806b69279be678dad2feb8099699' "$workflow"
grep -Fq 'observability_operations.yml' "$runner"
grep -Fq 'xconnect_remote_observation' "$runner"
grep -Fq 'inventory.ini' "$runner"
grep -Fq 'variables.json' "$runner"
grep -Fq 'trap '\''rm -rf -- "$observation_dir"'\'' EXIT' "$runner"
grep -Fq -- '--private-key "$LAB_DIR/id_ed25519"' "$runner"
grep -Fq 'UserKnownHostsFile=$LAB_DIR/known_hosts' "$runner"
grep -Fq 'xconnect_remote_observation_gateway_state_dir:"/var/lib/xconnect-gateway"' "$runner"
grep -Fq 'xconnect_remote_observation_client_state_dir:"/var/lib/xconnect-one"' "$runner"
grep -Fq 'NODE_OBSERVATION_RESULT=SUMMARY_ONLY local_independent_acceptance_required=true' "$runner"
if grep -Fq 'remote-gateway-observation.sh' "$runner" || grep -Fq 'remote-client-observation.sh' "$runner"; then
  echo 'node-observation must delegate remote checks to the Playbooks operation' >&2
  exit 1
fi
if grep -Eq 'terraform|manifest| xconnect-gateway up| xconnect sync|systemctl .*restart|service .*restart' "$runner"; then
  echo 'caller must not own Terraform/manifest or mutating remote operations' >&2
  exit 1
fi

echo 'xconnect_playbooks_observation_caller_contract_test: PASS'
