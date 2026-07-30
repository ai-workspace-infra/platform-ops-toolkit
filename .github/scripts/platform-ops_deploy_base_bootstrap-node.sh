#!/usr/bin/env bash
set -euo pipefail

: "${MATRIX_HOST:?MATRIX_HOST must be set (pass matrix.host via step env)}"

cmdb_file="../cmdb/cmdb.json"
mapfile -t node_groups < <(jq -r --arg host "${MATRIX_HOST}" '.[$host].groups[]? // empty' "${cmdb_file}")

playbook=""
for group in "${node_groups[@]}"; do
  case "${group}" in
    web_saas)
      playbook=setup-web-saas-domain.yml
      break
      ;;
    ai_workspace)
      playbook=setup-ai-workspace-rootless.yml
      break
      ;;
    agent_proxy)
      playbook=setup-agent-proxy-domain.yml
      break
      ;;
    infra_platform|open_platform)
      playbook=setup-open-platform-domain.yml
      break
      ;;
    k3s|k3s_server|k3s_agent)
      playbook=setup-k3s-node.yaml
      ;;
    k8s|k8s_node|gpu_k8s)
      playbook=setup-k8s-node.yaml
      ;;
  esac
done

if [[ -z "${playbook}" ]]; then
  echo "No bootstrap playbook mapping found for ${MATRIX_HOST}; CMDB groups: ${node_groups[*]:-none}" >&2
  exit 1
fi

echo "Bootstrapping ${MATRIX_HOST} with ${playbook}"
ansible-playbook -i ../cmdb/inventory.ini -l "${MATRIX_HOST}" "${playbook}"
