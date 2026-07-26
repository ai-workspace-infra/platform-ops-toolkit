#!/bin/bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env MATRIX_HOST

# Doco-CD applies the GitOps compose asynchronously. Retry until PostgreSQL is
# present, then let the idempotent playbook create missing databases and roles.
max_attempts="${DATABASE_INIT_MAX_ATTEMPTS:-18}"
attempt=1
while ! "$(dirname "${BASH_SOURCE[0]}")/common_provision_databases_and_roles.sh"; do
  if [[ "${attempt}" -ge "${max_attempts}" ]]; then
    echo "::error::PostgreSQL database initialization did not converge on ${MATRIX_HOST}." >&2
    exit 1
  fi
  echo "PostgreSQL is not ready on ${MATRIX_HOST}; retrying (${attempt}/${max_attempts})."
  attempt=$((attempt + 1))
  sleep 10
done

echo "Database users and databases are ready on ${MATRIX_HOST}."
