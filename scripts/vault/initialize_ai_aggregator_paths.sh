#!/usr/bin/env bash
set -Eeuo pipefail

# Initialize the non-value KV v2 records used by AI Aggregator v1.
#
# The default mode is read-only. `--apply` creates only missing records with
# an empty data object; it never writes, updates, or prints a secret value.
# Secret material must be provisioned separately through an approved Vault
# workflow.
umask 077

usage() {
  cat <<'EOF'
Usage:
  initialize_ai_aggregator_paths.sh [--check|--apply] [--env uat|prod|all]

Environment:
  VAULT_ADDR       Vault address (default: https://vault.svc.plus)
  VAULT_MOUNT      KV v2 mount name (default: kv)
  VAULT_TOKEN      Vault token; read from the environment, never an argument
  VAULT_NAMESPACE  Optional Vault Enterprise namespace

Examples:
  VAULT_TOKEN="..." initialize_ai_aggregator_paths.sh --check
  VAULT_TOKEN="..." initialize_ai_aggregator_paths.sh --apply --env uat
EOF
}

mode=check
target_env=all

while (($# > 0)); do
  case "$1" in
    --check)
      mode=check
      ;;
    --apply)
      mode=apply
      ;;
    --env)
      (($# >= 2)) || { echo "--env requires uat, prod, or all" >&2; exit 2; }
      target_env="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$target_env" in
  uat|prod|all) ;;
  *) echo "invalid environment: $target_env" >&2; exit 2 ;;
esac

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_MOUNT="${VAULT_MOUNT:-kv}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be provided through the environment}"

curl_headers=(-H "X-Vault-Token: ${VAULT_TOKEN}")
if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
  curl_headers+=(-H "X-Vault-Namespace: ${VAULT_NAMESPACE}")
fi

vault_status() {
  local api_path="$1"
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    "${curl_headers[@]}" "${VAULT_ADDR%/}/v1/${api_path}"
}

vault_write_empty() {
  local api_path="$1"
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --request POST \
    "${curl_headers[@]}" \
    -H 'Content-Type: application/json' \
    --data '{"data":{}}' \
    "${VAULT_ADDR%/}/v1/${api_path}"
}

health_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "${VAULT_ADDR%/}/v1/sys/health")"
if [[ "$health_status" != 200 ]]; then
  echo "Vault is not ready: HTTP ${health_status}" >&2
  exit 1
fi

mount_response="$(mktemp)"
trap 'rm -f "$mount_response"' EXIT
mount_status="$(curl --silent --show-error --output "$mount_response" --write-out '%{http_code}' \
  "${curl_headers[@]}" "${VAULT_ADDR%/}/v1/sys/mounts/${VAULT_MOUNT}")"
if [[ "$mount_status" != 200 ]] || ! jq -e --arg mount "${VAULT_MOUNT}/" \
  '.data[$mount].type == "kv" and .data[$mount].options.version == "2"' \
  "$mount_response" >/dev/null; then
  echo "${VAULT_MOUNT}/ is not an accessible KV v2 mount" >&2
  exit 1
fi

environments=(uat prod)
if [[ "$target_env" != all ]]; then
  environments=("$target_env")
fi

missing=0
for env_name in "${environments[@]}"; do
  api_base="${VAULT_MOUNT}/data/${env_name}/ai-aggregator"
  paths=(
    "${api_base}"
    "${api_base}/litellm/providers/openai"
    "${api_base}/litellm/providers/anthropic"
    "${api_base}/litellm/providers/xai"
    "${api_base}/database/new-api"
    "${api_base}/database/litellm"
    "${api_base}/database/backup"
    "${api_base}/gateway/caddy"
    "${api_base}/gateway/new-api"
    "${api_base}/gateway/litellm"
    "${api_base}/cpa/cpa-codex-01"
    "${api_base}/cpa/cpa-codex-02"
    "${api_base}/cpa/cpa-claude-01"
    "${api_base}/cpa/cpa-grok-01"
  )

  for api_path in "${paths[@]}"; do
    status="$(vault_status "$api_path")"
    case "$status" in
      200)
        echo "present ${api_path}"
        ;;
      404)
        if [[ "$mode" == check ]]; then
          echo "missing ${api_path}"
          missing=1
        else
          write_status="$(vault_write_empty "$api_path")"
          if [[ "$write_status" == 200 || "$write_status" == 204 ]]; then
            echo "created ${api_path}"
          else
            echo "failed to initialize ${api_path}: HTTP ${write_status}" >&2
            exit 1
          fi
        fi
        ;;
      403)
        echo "permission denied ${api_path}" >&2
        exit 1
        ;;
      *)
        echo "unexpected response for ${api_path}: HTTP ${status}" >&2
        exit 1
        ;;
    esac
  done
done

if [[ "$mode" == check && "$missing" != 0 ]]; then
  echo "Vault path check failed: one or more records are missing" >&2
  exit 1
fi

if [[ "$mode" == apply ]]; then
  echo "Vault path initialization completed; no secret values were written."
else
  echo "Vault path check completed."
fi
