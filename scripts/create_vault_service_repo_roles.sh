#!/usr/bin/env bash
set -euo pipefail

# Vault Authentication & Policy Split Initialization.
#
# This is intentionally an orchestration entrypoint. The authorization rules
# live in scripts/vault/policies/*.hcl and scripts/vault/roles/*.json.
#
# Requirements:
#   VAULT_ADDR   Vault address (default: https://vault.svc.plus)
#   VAULT_TOKEN  admin-capable token, or an authenticated Vault CLI session
#
# A role declaration contains a human-readable "description" and "role_name".
# Those metadata fields are stripped before the remaining JSON is sent to Vault.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
POLICY_DIR="${VAULT_POLICY_DEFINITION_DIR:-${SCRIPT_DIR}/vault/policies}"
ROLE_DIR="${VAULT_ROLE_DEFINITION_DIR:-${SCRIPT_DIR}/vault/roles}"

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

if [ -z "${VAULT_TOKEN:-}" ] && ! vault token lookup >/dev/null 2>&1; then
  echo "Error: no authenticated Vault CLI session is available." >&2
  echo "  export VAULT_ADDR=https://vault.svc.plus" >&2
  echo "  export VAULT_TOKEN=hvs.xxx  (admin token, do NOT commit it)" >&2
  exit 1
fi

for command_name in vault jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Error: ${command_name} is required." >&2
    exit 1
  }
done

[[ -d "${POLICY_DIR}" ]] || { echo "Missing policy directory: ${POLICY_DIR}" >&2; exit 1; }
[[ -d "${ROLE_DIR}" ]] || { echo "Missing role directory: ${ROLE_DIR}" >&2; exit 1; }

shopt -s nullglob
policy_files=("${POLICY_DIR}"/*.hcl)
role_files=("${ROLE_DIR}"/*.json)
(( ${#policy_files[@]} > 0 )) || { echo "No policy declarations found." >&2; exit 1; }
(( ${#role_files[@]} > 0 )) || { echo "No role declarations found." >&2; exit 1; }

echo "=== Provisioning Vault policies from ${POLICY_DIR} ==="
for policy_file in "${policy_files[@]}"; do
  policy_name="${policy_file##*/}"
  policy_name="${policy_name%.hcl}"
  [[ "${policy_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+@-]*[A-Za-z0-9]$ ]] || {
    echo "Invalid policy filename: ${policy_file}" >&2
    exit 1
  }
  echo "  Writing policy ${policy_name}..."
  vault policy write "${policy_name}" "${policy_file}"
done

echo "=== Provisioning Vault JWT roles from ${ROLE_DIR} ==="
for role_file in "${role_files[@]}"; do
  role_name="${role_file##*/}"
  role_name="${role_name%.json}"
  [[ "${role_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+@-]*[A-Za-z0-9]$ ]] || {
    echo "Invalid role filename: ${role_file}" >&2
    exit 1
  }

  jq -e --arg expected "${role_name}" '
    .role_name == $expected and
    (.description | type == "string" and length > 0) and
    .role_type == "jwt" and
    .user_claim == "sub" and
    (.bound_audiences | type == "array" and length > 0) and
    (.bound_claims | type == "object") and
    (.token_policies | type == "array" and length > 0) and
    .token_no_default_policy == true and
    .token_type == "batch" and
    (.token_ttl | type == "string" and length > 0) and
    (.token_max_ttl | type == "string" and length > 0)
  ' "${role_file}" >/dev/null || {
    echo "Invalid role declaration: ${role_file}" >&2
    exit 1
  }

  while IFS= read -r policy_name; do
    [[ "${policy_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+@-]*[A-Za-z0-9]$ ]] || {
      echo "Invalid policy reference in ${role_file}: ${policy_name}" >&2
      exit 1
    }
    [[ -f "${POLICY_DIR}/${policy_name}.hcl" ]] || {
      echo "Missing policy declaration for ${role_name}: ${policy_name}.hcl" >&2
      exit 1
    }
  done < <(jq -er '.token_policies[]' "${role_file}")

  echo "  Writing role ${role_name}..."
  jq -c 'del(.role_name, .description)' "${role_file}" |
    vault write "auth/jwt/role/${role_name}" -
done

echo "=== Cleaning up deprecated roles ==="
# GCP bootstrap roles are managed declarations and must never be removed by
# this entrypoint. Only this explicitly retired legacy role is cleaned up.
vault delete auth/jwt/role/github-actions-platform-ops-toolkit-prod-tags 2>/dev/null ||
  echo "  (github-actions-platform-ops-toolkit-prod-tags not present, skipped)"

echo
echo "========================================================================="
echo " Vault Authentication & Policy Consolidation Completed Successfully."
echo "========================================================================="
