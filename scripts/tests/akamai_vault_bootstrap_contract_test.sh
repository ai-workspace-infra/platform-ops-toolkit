#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
bootstrap="${repo_root}/scripts/vault/bootstrap_akamai_oidc_roles.sh"
consolidated="${repo_root}/scripts/create_vault_service_repo_roles.sh"

grep -Fq 'verify_role_claims "$env_name" "$account" "$role_name"' "${bootstrap}"
grep -Fq 'vault read -format=json "${VAULT_JWT_AUTH_MOUNT}/role/${role_name}"' "${bootstrap}"
grep -Fq 'VAULT_JWT_AUTH_MOUNT="${VAULT_JWT_AUTH_MOUNT:-auth/jwt}"' "${bootstrap}"
grep -Fq 'VAULT_JWT_AUTH_MOUNT="${VAULT_JWT_AUTH_MOUNT:-auth/jwt}"' "${consolidated}"
grep -Fq 'vault write "${VAULT_JWT_AUTH_MOUNT}/role/${role_name}" -' "${consolidated}"

bash -n "${bootstrap}" "${consolidated}"
echo "akamai_vault_bootstrap_contract: PASS"
