#!/usr/bin/env bash
set -euo pipefail

# Migrate KV v2 secret kv/CICD version 40 into:
#   kv/CICD                 shared credentials
#   kv/CICD/{sit,uat,prod}  environment-scoped infrastructure credentials
#
# Default is dry-run. Values are never printed, existing destination keys are
# preserved, and the source path/version is never deleted.

SOURCE_PATH="kv/CICD"
SOURCE_VERSION="40"
VAULT_ADDR="https://vault.svc.plus"
MODE="dry-run"
FORCE=0
UNCLASSIFIED_TO="fail"
TOKEN_VALUE=""

# Based on docs/vault/kv_layout_and_migration.md.
COMMON_KEYS="GHCR_USERNAME GHCR_TOKEN ROOT_BOOTSTRAP_PASSWORD"
BASE_KEYS="SSH_PRIVATE_DEPLOY_KEY_B64 VULTR_API_KEY TF_STATE_ENDPOINT TF_STATE_BUCKET TF_STATE_ACCESS_KEY TF_STATE_SECRET_KEY TF_STATE_REGION"

usage() {
  cat <<'EOF'
Usage:
  vault_migrate_cicd_details.sh [options]

Options:
  --apply                       Write changes. Default is dry-run.
  --force                       Replace existing destination keys.
  --token TOKEN                Supply Vault token explicitly (less safe).
  --token=TOKEN                Equivalent form.
  --source-path=PATH            Default: kv/CICD
  --source-version=VERSION      Default: 40
  --unclassified-to=DEST        DEST: fail, shared, envs, or leave. Default: fail.
                                shared writes unknown keys to kv/CICD.
                                envs writes unknown keys to all sit/uat/prod paths.
                                leave reports unknown keys, leaves them in the source,
                                and migrates only the classified keys.
  -h, --help                    Show this help.

If --token is omitted and VAULT_TOKEN is not exported, the script prompts
for it without echo. Command-line tokens may be visible in shell history.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --apply) MODE="apply" ;;
    --force) FORCE=1 ;;
    --token)
      shift
      [[ "$#" -gt 0 ]] || die "--token requires a value"
      TOKEN_VALUE="$1"
      ;;
    --token=*) TOKEN_VALUE=$(printf '%s' "$1" | cut -d= -f2-) ;;
    --source-path=*) SOURCE_PATH=$(printf '%s' "$1" | cut -d= -f2-) ;;
    --source-version=*) SOURCE_VERSION=$(printf '%s' "$1" | cut -d= -f2-) ;;
    --unclassified-to=*) UNCLASSIFIED_TO=$(printf '%s' "$1" | cut -d= -f2-) ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

case "$UNCLASSIFIED_TO" in
  fail|shared|envs|leave) ;;
  *) die "--unclassified-to must be fail, shared, envs, or leave" ;;
esac

require_command vault
require_command jq

if printenv VAULT_ADDR >/dev/null 2>&1; then
  VAULT_ADDR=$(printenv VAULT_ADDR)
fi
if [[ -n "$TOKEN_VALUE" ]]; then
  VAULT_TOKEN="$TOKEN_VALUE"
elif printenv VAULT_TOKEN >/dev/null 2>&1; then
  VAULT_TOKEN=$(printenv VAULT_TOKEN)
else
  read -r -s -p "Vault token for $VAULT_ADDR: " VAULT_TOKEN
  printf '\n' >&2
fi
[[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is empty"
TOKEN_VALUE=""
export VAULT_ADDR VAULT_TOKEN

TEMP_DIR=$(mktemp -d /tmp/vault-cicd-details.XXXXXX)
chmod 700 "$TEMP_DIR"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

SOURCE_JSON="$TEMP_DIR/source.json"
SOURCE_DATA="$TEMP_DIR/source-data.json"
SHARED_KEYS="$TEMP_DIR/shared.keys"
ENV_KEYS="$TEMP_DIR/env.keys"
UNKNOWN_KEYS="$TEMP_DIR/unknown.keys"
: > "$SHARED_KEYS"
: > "$ENV_KEYS"
: > "$UNKNOWN_KEYS"

printf 'Source: %s (version %s)\n' "$SOURCE_PATH" "$SOURCE_VERSION"
vault kv get -version="$SOURCE_VERSION" -format=json "$SOURCE_PATH" > "$SOURCE_JSON" \
  || die "unable to read $SOURCE_PATH version $SOURCE_VERSION"
jq -e '.data.data | type == "object"' "$SOURCE_JSON" >/dev/null \
  || die "source payload is not a KV v2 data object"
jq '.data.data' "$SOURCE_JSON" > "$SOURCE_DATA"

classify() {
  local key="$1"
  case " $COMMON_KEYS " in
    *" $key "*) printf 'shared'; return 0 ;;
  esac
  case " $BASE_KEYS " in
    *" $key "*) printf 'envs'; return 0 ;;
  esac
  printf 'unknown'
}

for key in $COMMON_KEYS $BASE_KEYS; do
  jq -e --arg key "$key" 'has($key)' "$SOURCE_DATA" >/dev/null \
    || die "source is missing required classified key: $key"
done

while IFS= read -r key; do
  case "$(classify "$key")" in
    shared) printf '%s\n' "$key" >> "$SHARED_KEYS" ;;
    envs) printf '%s\n' "$key" >> "$ENV_KEYS" ;;
    unknown) printf '%s\n' "$key" >> "$UNKNOWN_KEYS" ;;
  esac
done < <(jq -r 'keys[]' "$SOURCE_DATA")

if [[ -s "$UNKNOWN_KEYS" ]]; then
  printf 'Unclassified source keys (names only):\n' >&2
  sed 's/^/  /' "$UNKNOWN_KEYS" >&2
  case "$UNCLASSIFIED_TO" in
    fail)
      printf '%s\n' 'Migration stopped. Review the keys and rerun with an explicit classification.' >&2
      exit 2
      ;;
    leave)
      printf '%s\n' 'Continuing with classified keys only; unclassified keys remain in the source.' >&2
      ;;
    shared) cat "$UNKNOWN_KEYS" >> "$SHARED_KEYS" ;;
    envs) cat "$UNKNOWN_KEYS" >> "$ENV_KEYS" ;;
  esac
fi

printf 'Source keys: %s\n' "$(jq 'length' "$SOURCE_DATA")"
printf '%s\n' 'Shared destination: kv/CICD'
printf '%s\n' 'Environment destinations: kv/CICD/{sit,uat,prod}'
printf 'Mode: %s (%s existing keys)\n' "$MODE" "$([[ "$FORCE" -eq 1 ]] && printf 'replace' || printf 'preserve')"

write_subset() {
  local target="$1"
  local allowed_file="$2"
  local allowed_json
  local existing_json="$TEMP_DIR/existing.json"
  local existing_data="$TEMP_DIR/existing-data.json"
  local keys_file="$TEMP_DIR/write.keys"
  local merged_file="$TEMP_DIR/merged.json"

  allowed_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$allowed_file")
  if ! vault kv get -format=json "$target" > "$existing_json" 2>/dev/null; then
    printf '  %s: target absent; will create\n' "$target"
    printf '{}\n' > "$existing_json"
  fi
  jq '.data.data // {}' "$existing_json" > "$existing_data"

  jq -n \
    --slurpfile current "$existing_data" \
    --argjson allowed "$allowed_json" \
    --argjson force "$FORCE" \
    '$allowed | map(select($force == 1 or (($current[0] | has(.)) | not)))' \
    > "$keys_file"

  if [[ "$(jq 'length' "$keys_file")" == "0" ]]; then
    printf '  %s: no changes\n' "$target"
    return 0
  fi
  printf '  %s: keys=%s action=%s\n' "$target" "$(jq -r 'join(",")' "$keys_file")" "$MODE"
  [[ "$MODE" == "apply" ]] || return 0

  jq -n \
    --slurpfile source "$SOURCE_DATA" \
    --slurpfile current "$existing_data" \
    --slurpfile keys "$keys_file" \
    '($current[0] // {}) + (reduce $keys[0][] as $key ({}; .[$key] = $source[0][$key]))' \
    > "$merged_file"
  chmod 600 "$merged_file"
  vault kv put "$target" - < "$merged_file" >/dev/null
  printf '    written\n'
}

printf '%s\n' 'Plan (secret values are intentionally not displayed):'
write_subset kv/CICD "$SHARED_KEYS"
for env in sit uat prod; do
  write_subset "kv/CICD/$env" "$ENV_KEYS"
done

if [[ "$MODE" == "apply" ]]; then
  printf '%s\n' 'Verifying destination key names:'
  for target in kv/CICD kv/CICD/sit kv/CICD/uat kv/CICD/prod; do
    vault kv get -format=json "$target" \
      | jq -r --arg target "$target" '"  " + $target + ": " + ((.data.data // {}) | keys | join(","))'
  done
  printf '%s\n' 'Migration complete. Source path and version history were not deleted.'
else
  printf '%s\n' 'Dry-run complete. Re-run with --apply to write these changes.'
fi
