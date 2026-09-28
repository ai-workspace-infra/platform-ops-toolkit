#!/usr/bin/env bash
# Write or verify the short-lived AWS control-plane credential used only by
# aws-oidc-bootstrap.yml. Normal Terraform runs use GitHub OIDC and the
# environment's iac_state record; they must not read this path.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage:
  bootstrap_aws_auth_kv.sh --write --env uat|prod
  bootstrap_aws_auth_kv.sh --check --env uat|prod

Required for --write:
  VAULT_ADDR (default: https://vault.svc.plus)
  VAULT_TOKEN, or an authenticated Vault CLI session
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY

Optional for --write:
  AWS_SESSION_TOKEN  STS/IAM Identity Center session token
  VAULT_MOUNT        KV v2 mount (default: kv)

The record is kv/CICD/<env>/aws-bootstrap. It is a short-lived break-glass
credential for the AWS OIDC recovery workflow, not a normal deployment secret.
EOF
}

action="${AWS_BOOTSTRAP_ACTION:-check}"
environment="${AWS_ENVIRONMENT:-${ENV:-}}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
vault_mount="${VAULT_MOUNT:-kv}"

while (($# > 0)); do
  case "$1" in
    --write|--apply) action=write ;;
    --check) action=check ;;
    --env)
      (($# >= 2)) || { echo "--env requires uat or prod" >&2; exit 2; }
      environment="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "${action}" in
  check|write) ;;
  *) echo "AWS_BOOTSTRAP_ACTION must be check or write" >&2; exit 2 ;;
esac
case "${environment}" in
  uat|prod) ;;
  *) echo "AWS_ENVIRONMENT/ENV must be uat or prod" >&2; exit 2 ;;
esac
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || {
  echo "VAULT_ADDR must be an https:// or http:// Vault URL" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

secret_path="CICD/${environment}/aws-bootstrap"
api_url="${vault_addr%/}/v1/${vault_mount}/data/${secret_path}"

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
    VAULT_ADDR="${vault_addr}" vault kv get -mount="${vault_mount}" -format=json "${secret_path}"
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
    local payload_file
    payload_file="$(mktemp "${TMPDIR:-/tmp}/aws-bootstrap.XXXXXX")"
    chmod 600 "${payload_file}"
    trap 'rm -f -- "${payload_file}"' RETURN
    jq -e '.data | type == "object"' >"${payload_file}"
    jq '.data' "${payload_file}" >"${payload_file}.flat"
    VAULT_ADDR="${vault_addr}" vault kv put -mount="${vault_mount}" "${secret_path}" \
      "@${payload_file}.flat" >/dev/null
    rm -f -- "${payload_file}" "${payload_file}.flat"
    trap - RETURN
  fi
}

if [[ "${action}" == write ]]; then
  : "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required for --write}"
  : "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required for --write}"
  if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
      jq -n '{data:{AWS_ACCESS_KEY_ID:env.AWS_ACCESS_KEY_ID,
                    AWS_SECRET_ACCESS_KEY:env.AWS_SECRET_ACCESS_KEY,
                    AWS_SESSION_TOKEN:env.AWS_SESSION_TOKEN}}' | vault_write_json
  else
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
      jq -n '{data:{AWS_ACCESS_KEY_ID:env.AWS_ACCESS_KEY_ID,
                    AWS_SECRET_ACCESS_KEY:env.AWS_SECRET_ACCESS_KEY}}' | vault_write_json
  fi
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  echo "kv/${secret_path}: AWS bootstrap credential written"
else
  record="$(vault_read_json)"
  jq -e '
    (.data.data.AWS_ACCESS_KEY_ID | type == "string" and length > 0) and
    (.data.data.AWS_SECRET_ACCESS_KEY | type == "string" and length > 0) and
    ((.data.data.AWS_SESSION_TOKEN // "") | type == "string")
  ' <<<"${record}" >/dev/null || {
    echo "kv/${secret_path} is missing a valid AWS bootstrap credential" >&2
    exit 1
  }
  unset record
  echo "kv/${secret_path}: OK"
fi
