#!/usr/bin/env bash
set -euo pipefail
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
action=check
environments=(uat prod)
pepper="${BRIDGE_CREDENTIAL_TOKEN_PEPPER:-}"
while (($#)); do
  case "$1" in
    --write) action=write;; --check) action=check;;
    --env) [[ $# -ge 2 ]] || exit 2; case "$2" in uat) environments=(uat);; prod) environments=(prod);; all) environments=(uat prod);; *) exit 2;; esac; shift;;
    --pepper) [[ $# -ge 2 ]] || exit 2; pepper="$2"; shift;;
    -h|--help) echo "Usage: $0 [--check|--write] [--env uat|prod|all] [--pepper VALUE]"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac; shift
done
[[ "$vault_addr" =~ ^https://[^/]+/?$ ]] || { echo 'VAULT_ADDR must be an https:// Vault URL' >&2; exit 2; }
command -v vault >/dev/null || { echo 'vault CLI is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
export VAULT_ADDR="$vault_addr"
if [[ -z "${VAULT_TOKEN:-}" ]] && ! vault token lookup >/dev/null 2>&1; then echo 'Vault authentication is required' >&2; exit 1; fi
for env_name in "${environments[@]}"; do
  path="${env_name}/accounts/runtime"
  if [[ "$action" == check ]]; then
    record="$(vault kv get -mount=kv -format=json "$path")" || { echo "kv/data/$path: missing" >&2; exit 1; }
    jq -e '.data.data.BRIDGE_CREDENTIAL_TOKEN_PEPPER | type == "string" and length > 0' <<<"$record" >/dev/null || { echo "kv/data/$path: BRIDGE_CREDENTIAL_TOKEN_PEPPER missing" >&2; exit 1; }
    echo "kv/data/$path: BRIDGE_CREDENTIAL_TOKEN_PEPPER present"; continue
  fi
  if [[ -z "$pepper" ]]; then command -v openssl >/dev/null || exit 1; pepper="$(openssl rand -hex 32)"; fi
  [[ ${#pepper} -ge 32 ]] || { echo 'pepper must be at least 32 characters' >&2; exit 2; }
  vault kv patch -mount=kv "$path" BRIDGE_CREDENTIAL_TOKEN_PEPPER="$pepper" >/dev/null
  echo "kv/data/$path: BRIDGE_CREDENTIAL_TOKEN_PEPPER updated"
done
