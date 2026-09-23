#!/usr/bin/env bash
# Store or verify UCloud provider credentials in Vault KV v2.
# Path: kv/CICD/<env>/ucloud/<project_id>
#
# Required for write:
#   UCLOUD_ENVIRONMENT=sit|uat|prod
#   UCLOUD_PROJECT_ID, UCLOUD_PUBLIC_KEY, UCLOUD_PRIVATE_KEY, UCLOUD_REGION
# Optional:
#   VAULT_ADDR (defaults to https://vault.svc.plus)
#   VAULT_TOKEN (otherwise uses an authenticated Vault CLI session)
#   UCLOUD_BOOTSTRAP_ACTION=write|check (defaults to write)
#
# This initializes credentials for future provider execution. The current
# The standard UCloud Terraform workflow consumes these credentials. ULightHost
# remains on the separate existing-resource inventory route.
set -euo pipefail

environment="${UCLOUD_ENVIRONMENT:?UCLOUD_ENVIRONMENT is required (sit, uat or prod)}"
project_id="${UCLOUD_PROJECT_ID:?UCLOUD_PROJECT_ID is required}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
action="${UCLOUD_BOOTSTRAP_ACTION:-write}"

case "${environment}" in
  sit|uat|prod) ;;
  *) echo "UCLOUD_ENVIRONMENT must be sit, uat or prod" >&2; exit 1 ;;
esac
[[ "${project_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[A-Za-z0-9]$ ]] || {
  echo "UCLOUD_PROJECT_ID must be a path-safe UCloud project ID" >&2
  exit 1
}
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || {
  echo "VAULT_ADDR must be an https:// or http:// Vault URL" >&2
  exit 1
}
case "${action}" in
  write|check) ;;
  *) echo "UCLOUD_BOOTSTRAP_ACTION must be write or check" >&2; exit 1 ;;
esac
for command_name in curl jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required" >&2
    exit 1
  }
done

secret_path="CICD/${environment}/ucloud/${project_id}"
api_url="${vault_addr%/}/v1/kv/data/${secret_path}"

vault_token="${VAULT_TOKEN:-}"
if [[ -z "${vault_token}" ]]; then
  command -v vault >/dev/null 2>&1 || {
    echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
    exit 1
  }
  vault_token="$(VAULT_ADDR="${vault_addr}" vault token lookup -format=json 2>/dev/null |
    jq -er '.data.id | strings | select(length > 0)')" || {
      echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
      exit 1
    }
}

case "${action}" in
  check)
    curl --fail --silent --show-error \
      --header "X-Vault-Token: ${vault_token}" "${api_url}" |
      jq -e --arg project "${project_id}" \
        '.data.data |
         (.UCLOUD_PUBLIC_KEY | type == "string" and length > 0) and
         (.UCLOUD_PRIVATE_KEY | type == "string" and length > 0) and
         (.UCLOUD_PROJECT_ID | type == "string" and . == $project) and
         (.UCLOUD_REGION | type == "string" and length > 0)' >/dev/null
    echo "${secret_path}: OK"
    ;;
  write)
    : "${UCLOUD_PUBLIC_KEY:?UCLOUD_PUBLIC_KEY is required}"
    : "${UCLOUD_PRIVATE_KEY:?UCLOUD_PRIVATE_KEY is required}"
    : "${UCLOUD_REGION:?UCLOUD_REGION is required}"
    jq -n '{data:{UCLOUD_PUBLIC_KEY:env.UCLOUD_PUBLIC_KEY,
                   UCLOUD_PRIVATE_KEY:env.UCLOUD_PRIVATE_KEY,
                   UCLOUD_PROJECT_ID:env.UCLOUD_PROJECT_ID,
                   UCLOUD_REGION:env.UCLOUD_REGION}}' |
      curl --fail --silent --show-error \
        --header "X-Vault-Token: ${vault_token}" \
        --header "Content-Type: application/json" \
        --request POST --data-binary @- "${api_url}" >/dev/null
    echo "${secret_path}: UCloud credentials written"
    ;;
esac
