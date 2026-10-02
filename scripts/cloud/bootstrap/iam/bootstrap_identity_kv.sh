#!/usr/bin/env bash
# Write or verify a non-destructive identity integration record in Vault KV v2.
#
# The payload is supplied through a mode-0600 file so client secrets never
# appear in argv or logs. This helper stores integration metadata only; it does
# not create an IdP application, change a cloud account, or enable SSO.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage:
  bootstrap_identity_kv.sh --integration NAME --env sit|uat|prod \
    --account ACCOUNT --purpose workforce|workload|application --check
  bootstrap_identity_kv.sh --integration NAME --env sit|uat|prod \
    --account ACCOUNT --purpose PURPOSE --apply --payload-file FILE

The payload file must contain a JSON object. Existing records are merged with
CAS protection. A failed read never causes an empty record to be written.
Record: kv/iam/<env>/<integration>/<account>/<purpose>
EOF
}

action="check"
integration=""
environment=""
account=""
purpose=""
payload_file=""
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
vault_mount="${VAULT_MOUNT:-kv}"

while (($# > 0)); do
  case "$1" in
    --check) action=check ;;
    --apply) action=apply ;;
    --integration) (($# >= 2)) || { echo "--integration requires a value" >&2; exit 2; }; integration="$2"; shift ;;
    --env) (($# >= 2)) || { echo "--env requires sit, uat or prod" >&2; exit 2; }; environment="$2"; shift ;;
    --account) (($# >= 2)) || { echo "--account requires a value" >&2; exit 2; }; account="$2"; shift ;;
    --purpose) (($# >= 2)) || { echo "--purpose requires a value" >&2; exit 2; }; purpose="$2"; shift ;;
    --payload-file) (($# >= 2)) || { echo "--payload-file requires a path" >&2; exit 2; }; payload_file="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$action" in check|apply) ;; *) echo "action must be check or apply" >&2; exit 2 ;; esac
case "$environment" in sit|uat|prod) ;; *) echo "--env must be sit, uat or prod" >&2; exit 2 ;; esac
case "$purpose" in workforce|workload|application) ;; *) echo "--purpose must be workforce, workload or application" >&2; exit 2 ;; esac
[[ "$integration" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "--integration must be path-safe" >&2; exit 2; }
[[ "$account" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || { echo "--account must be path-safe" >&2; exit 2; }
[[ "$vault_addr" =~ ^https?://[^/]+/?$ ]] || { echo "VAULT_ADDR must be an http(s) URL" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v vault >/dev/null 2>&1 || { echo "vault CLI is required" >&2; exit 1; }

required_fields_for() {
  case "${integration}:${purpose}" in
    gcp:workforce) echo "issuer,client_id,audience,workforce_pool_provider" ;;
    gcp:workload) echo "issuer,audience,workload_identity_provider,service_account" ;;
    aws:workforce) echo "issuer,entity_id,acs_url,saml_metadata_sha256" ;;
    aws:workload) echo "issuer,audience,oidc_provider_arn,role_arn,subject" ;;
    linode:workforce) echo "entity_id,acs_url,saml_metadata_sha256" ;;
    linode:workload) echo "api_credential_ref" ;;
    vultr:workforce) echo "issuer,client_id,redirect_uri" ;;
    vultr:workload) echo "api_credential_ref" ;;
    ucloud-global:workforce) echo "entity_id,acs_url,company_id,nameid_attribute" ;;
    ucloud-global:workload) echo "api_credential_ref" ;;
    grafana:application) echo "issuer,client_id,redirect_uri,role_claim" ;;
    *) echo "" ;;
  esac
}

required_fields="$(required_fields_for)"
[[ -n "$required_fields" ]] || { echo "unsupported integration/purpose combination" >&2; exit 2; }
validate_required_fields() {
  local json_file="$1" field
  local IFS=,
  for field in $required_fields; do
    jq -e --arg field "$field" '.[$field] | type == "string" and length > 0' "$json_file" >/dev/null || {
      echo "missing required identity field: ${field}" >&2
      return 1
    }
  done
}

if [[ "$action" == apply ]]; then
  [[ -n "$payload_file" && -f "$payload_file" ]] || { echo "--payload-file is required for --apply" >&2; exit 2; }
  payload_mode="$(stat -c '%a' "$payload_file" 2>/dev/null || true)"
  [[ -n "$payload_mode" ]] || payload_mode="$(stat -f '%Lp' "$payload_file" 2>/dev/null || true)"
  [[ "$payload_mode" == "600" ]] || {
    echo "payload file must have mode 0600" >&2
    exit 2
  }
  jq -e 'type == "object" and (keys | all(. != "__secret"))' "$payload_file" >/dev/null || {
    echo "payload file must contain a JSON object" >&2
    exit 2
  }
  validate_required_fields "$payload_file" || exit 2
fi

secret_path="iam/${environment}/${integration}/${account}/${purpose}"
export VAULT_ADDR="$vault_addr"
vault token lookup >/dev/null 2>&1 || {
  echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
  exit 1
}

current_json=""
current_version=0
read_error_file="$(mktemp "${TMPDIR:-/tmp}/identity-kv-read.XXXXXX")"
current_fields_file=""
trap 'rm -f "$read_error_file" "$current_fields_file"' EXIT
if current_json="$(vault kv get -mount="$vault_mount" -format=json "$secret_path" 2>"$read_error_file")"; then
  current_version="$(jq -er '.data.metadata.version | numbers' <<<"$current_json")"
else
  read_error="$(< "$read_error_file")"
  if [[ "$action" == check ]]; then
    echo "kv/${secret_path}: missing or unreadable" >&2
    exit 1
  fi
  if [[ "$read_error" != *"No value found at"* ]]; then
    echo "Vault read failed for kv/${secret_path}; refusing to create a record" >&2
    exit 1
  fi
  current_json='{"data":{"data":{}}}'
fi

if [[ "$action" == check ]]; then
  current_fields_file="$(mktemp "${TMPDIR:-/tmp}/identity-kv-current.XXXXXX")"
  chmod 600 "$current_fields_file"
  jq '.data.data' <<<"$current_json" >"$current_fields_file"
  validate_required_fields "$current_fields_file" || {
    rm -f "$current_fields_file"
    echo "kv/${secret_path}: required fields are missing" >&2
    exit 1
  }
  rm -f "$current_fields_file"
  current_fields_file=""
  jq -e '.data.data | type == "object" and length > 0' <<<"$current_json" >/dev/null || {
    echo "kv/${secret_path}: empty record" >&2
    exit 1
  }
  echo "kv/${secret_path}: OK (version ${current_version})"
  exit 0
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/identity-kv.XXXXXX")"
chmod 700 "$tmp_dir"
rm -f "$read_error_file"
trap 'rm -rf "$tmp_dir"; rm -f "$read_error_file" "$current_fields_file"' EXIT
merged_file="$tmp_dir/merged.json"
jq -s '.[0] + .[1]' \
  <(jq '.data.data' <<<"$current_json") \
  "$payload_file" >"$merged_file"

if [[ "$current_version" == 0 ]]; then
  vault kv put -cas=0 -mount="$vault_mount" "$secret_path" "@$merged_file" >/dev/null
else
  vault kv put -cas="$current_version" -mount="$vault_mount" "$secret_path" "@$merged_file" >/dev/null
fi
echo "kv/${secret_path}: identity metadata written"
