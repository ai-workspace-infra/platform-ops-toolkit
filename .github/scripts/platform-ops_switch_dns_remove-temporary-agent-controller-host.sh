#!/usr/bin/env bash
set -euo pipefail

if [[ "${INPUT_RUN_INFRASTRUCTURE:-false}" == "true" ]]; then
  inventory_path="../cmdb/inventory.ini"
else
  inventory_path="../platform-ops-toolkit/inventory.ini"
fi

cd playbooks

# DNS now points accounts-<env> at the current Web SaaS host.  Remove the
# bootstrap-only /etc/hosts override so a future console replacement is not
# shadowed by a stale IP on a long-lived agent-proxy host.
ansible agent_proxy -i "${inventory_path}" \
  -m ansible.builtin.lineinfile \
  -a "path=/etc/hosts regexp='^[[:space:]]*[^#[:space:]]+[[:space:]]+[^#[:space:]]+[[:space:]]+# platform-ops temporary agent controller$' state=absent" \
  --private-key ~/.ssh/id_deploy \
  --ssh-common-args=-o\ StrictHostKeyChecking=no \
  --become
