#!/usr/bin/env bash
# Run the non-playbook part of a node stage (see stage_plan.py "action").
#
#   run_stage_action.sh ACTION CONTRACT SSH_KEY KNOWN_HOSTS CONFIRM LEGACY_CONFIG
#
# legacy-convert / legacy-rollback / remove-legacy run legacy_convert.sh on
# the existing node over the pinned SSH channel. cutover / remove-legacy call
# the Vault API from the runner with the stage's scoped token (VAULT_ADDR,
# VAULT_TOKEN in the environment).
set -euo pipefail

action="$1" contract="$2" key="$3" known_hosts="$4" confirm="$5" legacy_config="$6"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

legacy() { jq -er --arg field "$1" '.spec.nodes[] | select(.groups | index("vault_legacy_source")) | .[$field]' "${contract}"; }
new_ids() { jq -r '[.spec.nodes[] | select((.groups | index("vault_legacy_source")) | not) | .id] | join(" ")' "${contract}"; }

on_legacy() {
  local port user address
  port="$(jq -er '.spec.nodes[] | select(.groups | index("vault_legacy_source")) | .ssh_port // 22' "${contract}")"
  user="$(legacy ssh_user)"
  address="$(legacy address)"
  ssh -i "${key}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" -o HostKeyAlgorithms=ssh-ed25519 \
    -p "${port}" "${user}@${address}" sudo -n bash -s -- "$@" <"${script_dir}/legacy_convert.sh"
}

case "${action}" in
  legacy-convert)
    iface="$(jq -er .overlay_interface <<<"${legacy_config}")"
    on_legacy plan "$(legacy id)" "$(legacy overlay_address)" "${iface}"
    on_legacy apply "$(legacy id)" "$(legacy overlay_address)" "${iface}" "${confirm}"
    ;;
  legacy-rollback)
    on_legacy rollback "${confirm}"
    ;;
  cutover)
    # shellcheck disable=SC2046
    python3 "${script_dir}/vault_raft_operator.py" step-down --legacy-id "$(legacy id)" --expect $(new_ids)
    ;;
  remove-legacy)
    # shellcheck disable=SC2046
    python3 "${script_dir}/vault_raft_operator.py" remove-peer --legacy-id "$(legacy id)" --expect $(new_ids)
    on_legacy retire "${confirm}"
    ;;
  *)
    echo "::error::unknown stage action ${action}" >&2
    exit 1
    ;;
esac
