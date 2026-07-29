#!/bin/bash
set -eo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"

require_env MATRIX_HOST

# observability_endpoint is provided by workflow input, Vault config provides VECTOR_AUTH_USER and VECTOR_AUTH_PASSWORD.
ansible-playbook -i ../cmdb/inventory.ini deploy_observability_agent.yml \
  --limit "${MATRIX_HOST}" \
  -e "vector_observability_endpoint=${OBSERVABILITY_ENDPOINT}" \
  -e "vector_auth_user=${VECTOR_AUTH_USER}" \
  -e "vector_auth_password=${VECTOR_AUTH_PASSWORD}"
