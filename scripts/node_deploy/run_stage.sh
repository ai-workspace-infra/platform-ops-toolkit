#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s CONTRACT.json PLAYBOOK.yml STAGE PLAYBOOKS_ROOT\n' "$0"
}

if [[ $# -ne 4 ]]; then
  usage >&2
  exit 2
fi

contract_path="$1"
playbook_path="$2"
stage="$3"
playbooks_root="$4"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for required in python3 jq ansible-playbook; do
  command -v "${required}" >/dev/null 2>&1 || {
    echo "${required} is required" >&2
    exit 1
  }
done
[[ -s "${contract_path}" ]] || { echo "NodeDeployment contract is missing" >&2; exit 1; }
[[ -f "${playbooks_root}/${playbook_path}" ]] || { echo "Playbook not found" >&2; exit 1; }

inventory="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/node-inventory.XXXXXX")"
chmod 600 "${inventory}"
cleanup() {
  rm -f -- "${inventory}"
}
trap cleanup EXIT

python3 "${script_dir}/render_inventory.py" "${contract_path}" --inventory "${inventory}" >/dev/null
python3 - "${contract_path}" "${stage}" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if sys.argv[2] not in doc["spec"]["stages"]:
    raise SystemExit(f"stage {sys.argv[2]!r} is not declared in this NodeDeployment contract")
PY

ready_adapters=",${NODE_AUTH_ADAPTERS_READY:-},"
stage_limit="$(jq -r --arg stage "${stage}" '.spec.stage_targets[$stage] | join(",")' "${contract_path}")"
if [[ -n "${NODE_STAGE_ONLY:-}" ]]; then
  # One-node stages: the selected node, and only if the stage targets it.
  jq -e --arg node "${NODE_STAGE_ONLY}" --arg stage "${stage}" \
    '.spec as $spec | any($spec.nodes[]; .id == $node and any(.groups[]; . as $group | $spec.stage_targets[$stage] | index($group)))' \
    "${contract_path}" >/dev/null || { echo "${NODE_STAGE_ONLY} is not a target of ${stage}" >&2; exit 1; }
  stage_limit="${NODE_STAGE_ONLY}"
fi
while IFS= read -r adapter; do
  [[ -n "${adapter}" ]] || continue
  [[ "${ready_adapters}" == *",${adapter},"* ]] || {
    echo "No prepared, short-lived credential adapter for ${adapter}; refusing SSH deployment" >&2
    exit 1
  }
done < <(
  jq -r --arg stage "${stage}" \
    '.spec as $spec | [$spec.nodes[] as $node | select(any($spec.stage_targets[$stage][]; . as $group | (($node.groups // ["vault_shared_nodes"]) | index($group)))) | $node.auth.adapter] | unique[]' \
    "${contract_path}"
)

extra_args=()
if [[ -n "${NODE_STAGE_EXTRA_VARS:-}" && "${NODE_STAGE_EXTRA_VARS}" != '{}' ]]; then
  jq -e . >/dev/null <<<"${NODE_STAGE_EXTRA_VARS}" || { echo "NODE_STAGE_EXTRA_VARS is not valid JSON" >&2; exit 1; }
  extra_args=(--extra-vars "${NODE_STAGE_EXTRA_VARS}")
fi

export ANSIBLE_HOST_KEY_CHECKING=True
ansible-playbook \
  -i "${inventory}" \
  "${playbooks_root}/${playbook_path}" \
  --limit "${stage_limit}" \
  --tags "${stage}" \
  "${extra_args[@]}"
