#!/usr/bin/env bash
set -euo pipefail

environment="${GCP_ENVIRONMENT:?GCP_ENVIRONMENT is required (uat or prod)}"
account_id="${GCP_ACCOUNT_ID:?GCP_ACCOUNT_ID is required}"
project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
action="${GCP_BOOTSTRAP_ACTION:-write}"

case "${environment}" in
  uat) default_project="xwork-open-platform-uat" ;;
  prod) default_project="xwork-open-platform-prod" ;;
  *) echo "GCP_ENVIRONMENT must be uat or prod" >&2; exit 1 ;;
esac
[[ "${account_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+@-]{0,126}[A-Za-z0-9]$ ]] || {
  echo "GCP_ACCOUNT_ID must be a stable name or email-like identifier without '/'" >&2
  exit 1
}
[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
  echo "GCP_PROJECT_ID must be a valid GCP project ID" >&2
  exit 1
}
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || {
  echo "VAULT_ADDR must be an https:// or http:// Vault URL" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# xworktech is the initial account contract. Additional accounts must provide
# an explicit project mapping; silently accepting an arbitrary project would
# allow a caller to write one account's bootstrap token under another target.
expected_project="${GCP_EXPECTED_PROJECT_ID:-}"
if [[ -z "${expected_project}" ]]; then
  if [[ "${account_id}" == "xworktech" ]]; then
    expected_project="${default_project}"
  else
    echo "GCP_EXPECTED_PROJECT_ID is required for non-xworktech accounts" >&2
    exit 1
  fi
fi
if [[ "${project_id}" != "${expected_project}" ]]; then
  echo "GCP_PROJECT_ID does not match GCP_ENVIRONMENT/account" >&2
  exit 1
fi

secret_path="CICD/${environment}/gcp-bootstrap/${account_id}"
api_url="${vault_addr%/}/v1/kv/data/${secret_path}"

vault_cli_session_available() {
  command -v vault >/dev/null 2>&1 &&
    VAULT_ADDR="${vault_addr}" vault token lookup >/dev/null 2>&1
}

vault_read_json() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    command -v curl >/dev/null 2>&1 || { echo "curl is required with VAULT_TOKEN" >&2; exit 1; }
    curl --fail --silent --show-error \
      --header "X-Vault-Token: ${VAULT_TOKEN}" "${api_url}"
  else
    vault_cli_session_available || {
      echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
      exit 1
    }
    VAULT_ADDR="${vault_addr}" vault kv get -mount=kv -format=json "${secret_path}"
  fi
}

vault_write_json() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    command -v curl >/dev/null 2>&1 || { echo "curl is required with VAULT_TOKEN" >&2; exit 1; }
    curl --fail --silent --show-error \
      --header "X-Vault-Token: ${VAULT_TOKEN}" \
      --header "Content-Type: application/json" \
      --request POST --data-binary @- "${api_url}" >/dev/null
  else
    vault_cli_session_available || {
      echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
      exit 1
    }
    # KV CLI input is a flat object (the HTTP API wrapper is not accepted).
    input_file="$(mktemp "${TMPDIR:-/tmp}/gcp-bootstrap-input.XXXXXX")"
    payload_file="$(mktemp "${TMPDIR:-/tmp}/gcp-bootstrap-payload.XXXXXX")"
    trap 'rm -f "${input_file}" "${payload_file}"' RETURN
    cat >"${input_file}"
    jq -e '.data | type == "object"' "${input_file}" >/dev/null
    jq '.data' "${input_file}" >"${payload_file}"
    VAULT_ADDR="${vault_addr}" vault kv put -mount=kv "${secret_path}" "@${payload_file}" >/dev/null
    rm -f "${input_file}" "${payload_file}"
    trap - RETURN
  fi
}

case "${action}" in
  check)
    vault_read_json |
      jq -e --arg project "${project_id}" \
        '.data.data |
         (.GCP_ACCESS_TOKEN | type == "string" and length > 0) and
         (.GCP_PROJECT_ID | type == "string" and . == $project)' \
        >/dev/null
    echo "${secret_path}: OK"
    ;;
  write)
    access_token="${GCP_ACCESS_TOKEN:-}"
    if [ -z "${access_token}" ]; then
      command -v gcloud >/dev/null 2>&1 || { echo "gcloud is required when GCP_ACCESS_TOKEN is unset" >&2; exit 1; }
      if ! access_token="$(gcloud auth application-default print-access-token)"; then
        echo "Unable to obtain a GCP access token. Run: gcloud auth application-default login" >&2
        exit 1
      fi
    fi
    test -n "${access_token}" || { echo "GCP access token is empty" >&2; exit 1; }
    GCP_ACCESS_TOKEN="${access_token}" GCP_PROJECT_ID="${project_id}" jq -n \
      '{data:{GCP_ACCESS_TOKEN:env.GCP_ACCESS_TOKEN,GCP_PROJECT_ID:env.GCP_PROJECT_ID}}' |
      vault_write_json
    unset access_token GCP_ACCESS_TOKEN
    echo "${secret_path}: written"
    ;;
  *)
    echo "GCP_BOOTSTRAP_ACTION must be write or check" >&2
    exit 1
    ;;
esac
