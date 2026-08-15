#!/bin/bash
set -euo pipefail

# Check if Ansible inventory is empty
if ! ansible all --list-hosts -i cmdb/inventory.ini 2>/dev/null | grep -q '^\s\+'; then
  echo "ERROR: Ansible inventory is empty (0 hosts). Aborting to prevent false successes." >&2
  exit 1
fi

make ${PROVISION_TOOLKIT_ACTION} DOMAIN=${PROVISION_TARGET_DOMAINS} RUN_ARGS="-e source_host=${PROVISION_SOURCE_HOST} -e target_host=www${PROVISION_ENV_SUFFIX}.${PROVISION_TARGET_DOMAIN_BASE} -e target_domain=${PROVISION_TARGET_DOMAIN_BASE} -e migration_flow.source.domain_base=${PROVISION_SOURCE_DOMAIN_BASE}"
