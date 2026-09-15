#!/usr/bin/env bash
set -euo pipefail

environment="${GCP_ENVIRONMENT:?GCP_ENVIRONMENT is required (uat or prod)}"
account_id="${GCP_ACCOUNT_ID:?GCP_ACCOUNT_ID is required}"
project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
action="${GCP_BOOTSTRAP_ACTION:-write}"

case "${environment}" in
  uat) expected_project="xworktech-open-platform-uat" ;;
  prod) expected_project="xworktech-open-platform-prod" ;;
  *) echo "GCP_ENVIRONMENT must be uat or prod" >&2; exit 1 ;;
esac
[[ "${account_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+@-]{0,126}[A-Za-z0-9]$ ]] || {
  echo "GCP_ACCOUNT_ID must be a stable name or email-like identifier without '/'" >&2
  exit 1
}
test "${project_id}" = "${expected_project}" || {
  echo "GCP_PROJECT_ID does not match GCP_ENVIRONMENT" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
test -n "${VAULT_TOKEN:-}" || { echo "VAULT_TOKEN is required" >&2; exit 1; }

secret_path="CICD/${environment}/gcp-bootstrap/${account_id}"
api_url="${vault_addr%/}/v1/kv/data/${secret_path}"

case "${action}" in
  check)
    curl --fail --silent --show-error \
      --header "X-Vault-Token: ${VAULT_TOKEN}" "${api_url}" |
      jq -e --arg project "${project_id}" \
        '.data.data | has("GCP_ACCESS_TOKEN") and .GCP_ACCESS_TOKEN != "" and .GCP_PROJECT_ID == $project' \
        >/dev/null
    echo "${secret_path}: OK"
    ;;
  write)
    access_token="${GCP_ACCESS_TOKEN:-}"
    if [ -z "${access_token}" ]; then
      command -v gcloud >/dev/null 2>&1 || { echo "gcloud is required when GCP_ACCESS_TOKEN is unset" >&2; exit 1; }
      access_token="$(gcloud auth application-default print-access-token)"
    fi
    test -n "${access_token}" || { echo "GCP access token is empty" >&2; exit 1; }
    GCP_ACCESS_TOKEN="${access_token}" GCP_PROJECT_ID="${project_id}" jq -n \
      '{data:{GCP_ACCESS_TOKEN:env.GCP_ACCESS_TOKEN,GCP_PROJECT_ID:env.GCP_PROJECT_ID}}' |
      curl --fail --silent --show-error \
        --header "X-Vault-Token: ${VAULT_TOKEN}" \
        --header "Content-Type: application/json" \
        --request POST --data-binary @- "${api_url}" >/dev/null
    unset access_token GCP_ACCESS_TOKEN
    echo "${secret_path}: written"
    ;;
  *)
    echo "GCP_BOOTSTRAP_ACTION must be write or check" >&2
    exit 1
    ;;
esac
