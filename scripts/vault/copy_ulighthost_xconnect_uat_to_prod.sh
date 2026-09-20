#!/usr/bin/env bash
set -euo pipefail

# Copy the UAT Ulighthost XConnect records to the canonical PROD paths.
# The default mode is read-only. Use --apply to write; add --overwrite when
# an existing PROD record is intentionally being replaced.

usage() {
  cat <<'USAGE'
Usage:
  copy_ulighthost_xconnect_uat_to_prod.sh [--check|--apply] [--overwrite]

Environment:
  VAULT_ADDR   Vault address, for example https://vault.svc.plus
  VAULT_TOKEN  Vault token with read access to UAT and write access to PROD

Examples:
  bash scripts/vault/copy_ulighthost_xconnect_uat_to_prod.sh --check
  bash scripts/vault/copy_ulighthost_xconnect_uat_to_prod.sh --apply
  bash scripts/vault/copy_ulighthost_xconnect_uat_to_prod.sh --apply --overwrite
USAGE
}

mode=check
overwrite=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode=check ;;
    --apply) mode=apply ;;
    --overwrite) overwrite=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"

command -v vault >/dev/null || { echo 'vault CLI is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ulighthost-xconnect-copy.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT
chmod 700 "${tmp_dir}"

records=(
  'tw-xconnect.svc.plus'
  'ph-xconnect.svc.plus'
)

metadata_exists() {
  local path="$1"
  vault kv metadata get -mount=kv "$path" >/dev/null 2>&1
}

validate_record() {
  local name="$1" payload="$2"
  jq -e --arg name "$name" '
    if $name == "tw-xconnect.svc.plus" then
      (.endpoint_host and .endpoint_port and .host and .user and
       .password and .ssh_private_key_b64)
    else
      ((.public_ipv4 // .host) and (.ansible_user // .user) and
       (.SSH_PASSWORD // .password // .ansible_password))
    end
  ' "$payload" >/dev/null || {
    echo "source record is missing required connection fields: ${name}" >&2
    exit 1
  }
}

for record in "${records[@]}"; do
  source_path="uat/ulighthost-xconnect/${record}"
  target_path="prod/ulighthost-xconnect/${record}"
  payload="${tmp_dir}/${record}.json"

  vault kv get -mount=kv -format=json "$source_path" \
    | jq --arg record "$record" '.data.data | if $record == "tw-xconnect.svc.plus" then .environment = "prod" else . end' \
    >"$payload"
  chmod 600 "$payload"
  validate_record "$record" "$payload"

  if metadata_exists "$target_path"; then
    if [[ "$mode" == check ]]; then
      echo "target exists: ${target_path} (use --apply --overwrite to replace)"
      continue
    fi
    if [[ "$overwrite" != true ]]; then
      echo "refusing to overwrite existing PROD record: ${target_path}" >&2
      echo 'rerun with --apply --overwrite if replacement is intentional' >&2
      exit 1
    fi
  fi

  if [[ "$mode" == check ]]; then
    echo "ready to copy: ${source_path} -> ${target_path}"
  else
    vault kv put -mount=kv "$target_path" "@${payload}" >/dev/null
    echo "written ${target_path}"
  fi
done

if [[ "$mode" == check ]]; then
  echo 'UAT-to-PROD Ulighthost XConnect check completed; no writes performed.'
fi
