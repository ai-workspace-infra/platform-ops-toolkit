#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/scripts/vault/vault-unseal-local.sh"

bash -n "$script"
grep -Fq 'set +x' "$script"
grep -Fq 'IFS= read -r -s' "$script"
grep -Fq '"$vault_addr/v1/sys/unseal"' "$script"
grep -Fq '"$vault_addr/v1/sys/seal-status"' "$script"
grep -Fq 'Vault returned invalid unseal progress/threshold' "$script"
grep -Fq -- '--data-binary @-' "$script"
grep -Fq 'unset unseal_share' "$script"
grep -Fq 'Vault is not initialized; refusing unseal' "$script"
grep -Fq 'Refusing non-loopback Vault address' "$script"

if rg -n 'VAULT_TOKEN|root.token|unseal_keys_b64|credentials.json|mktemp|tee ' "$script"; then
  echo "Unseal helper must not accept/persist root credentials, aggregate keys, or write temporary key files" >&2
  exit 1
fi

echo "vault_unseal_local_contract_test: PASS"
