#!/usr/bin/env bash
set -euo pipefail
root="${1:-$(pwd)}"
registry="${2:-$root/scripts/ci/control-plane-legacy.yaml}"
checker_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for tool in yq jq grep git shasum awk sed sort python3; do
  command -v "$tool" >/dev/null || { echo "::error::Missing ownership checker dependency: $tool" >&2; exit 2; }
done
yq -o=json '.' "$registry" > "$tmp/registry"
jq -e '.schema == 1 and (.legacy | type == "array")' "$tmp/registry" >/dev/null
# Search errors must fail the checker, rather than being treated as no match.
matches() {
  local status=0
  grep "$@" || status=$?
  case "$status" in 0) return 0 ;; 1) return 1 ;; *) echo '::error::Ownership source search failed' >&2; exit 2 ;; esac
}
errors=0
fail() { echo "::error::$1" >&2; errors=$((errors+1)); }
while IFS=$'\t' read -r path expected; do
  if [[ -f "$root/$path" ]]; then
    actual="$(shasum -a 256 "$root/$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || fail "Frozen execution bytes changed: $path"
  fi
done < <(jq -r '.legacy[] | [.path,.sha256] | @tsv' "$tmp/registry")
# No filename-based *_test.sh exemption. Test fixtures live in explicit test
# directories; a production workflow cannot hide k6 behind that suffix.
pattern='(^|[;&|]|\$\()[[:space:]]*((if|elif|then|do|while|until|!|exec|sudo|command|run_gcloud)[[:space:]]+)*(timeout[[:space:]]+("[^"]*"|[^[:space:]]+)[[:space:]]+)?(ssh|sshpass|scp|ansible-playbook|ansible|docker|systemctl|sysctl|wg|apt-get|pg_dump|pg_restore|psql|terraform|gcloud|aws|wrangler)[[:space:]]'
while IFS= read -r relative; do
  case "$relative" in */tests/*) continue ;; *.sh|*/action.yml) ;; *) continue ;; esac
  file="$root/$relative"
  [[ -f "$file" ]] || continue
  # Join continuations, discard full-line comments and preserve invocations.
  awk '!/^[[:space:]]*#/ { if (sub(/\\$/, "")) { printf "%s ", $0 } else print }' "$file" |
    sed -E 's/gcloud[[:space:]]+run[[:space:]]+(services|revisions)[[:space:]]+describe/toolkit_metadata_gate/g; s/docker[[:space:]]+buildx[[:space:]]+imagetools[[:space:]]+inspect/toolkit_metadata_gate/g; s/aws[[:space:]]+sts[[:space:]]+get-caller-identity/toolkit_identity_gate/g' > "$tmp/source"
  if matches -Eq "$pattern" "$tmp/source"; then
    jq -e --arg path "$relative" 'any(.legacy[]; .path == $path)' "$tmp/registry" >/dev/null ||
      fail "Execution must move to an owner: $relative"
  fi
done < <(git -C "$root" ls-files -co --exclude-standard .github/scripts .github/actions scripts/serverless_uat scripts/node_deploy | sort -u)
# Use the Python-aware inventory for subprocess calls and local import/source
# chains. Every production execution path must already be byte-frozen.
python3 "$checker_dir/script_ownership_verify.py" --root "$root" --inventory-only > "$tmp/python-inventory"
while IFS= read -r relative; do
  jq -e --arg path "$relative" 'any(.legacy[]; .path == $path)' "$tmp/registry" >/dev/null ||
    fail "Execution or imported execution chain must move to an owner: $relative"
done < <(jq -r '.legacy_execution | keys[]' "$tmp/python-inventory")
# Scan direct callers as well as their frozen implementation. Thin wrappers
# cannot remain the formal route after their owner caller has been switched.
while IFS= read -r entry; do
  if matches -Frql -- "$entry" "$root/.github/workflows"; then fail "Retired execution route remains active: $entry"; fi
done < <(jq -r '.retired_workflow_entries[]' "$tmp/registry")
# The Vault workflow may keep declaration and stage_plan control logic. Host,
# service and provider execution must use the exact Playbooks/IaC owner paths.
vault_workflow="$root/.github/workflows/vault-server.yml"
if [[ -f "$vault_workflow" ]]; then
  while IFS= read -r entry; do
    if matches -Fq -- "$entry" "$vault_workflow"; then fail "Vault workflow returned to frozen execution: $entry"; fi
  done < <(jq -r '.vault_server_forbidden_entries[]? // empty' "$tmp/registry")
  while IFS= read -r entry; do
    if [[ "$entry" == *vault-node-stage* && ! "$entry" =~ uses:[[:space:]]+ai-workspace-infra/playbooks/\.github/actions/vault-node-stage@[0-9a-f]{40}[[:space:]]*$ ]]; then
      fail "Vault node stage must use an exact Playbooks owner SHA: $entry"
    elif [[ "$entry" == *node-access-gcp* && ! "$entry" =~ uses:[[:space:]]+\./iac_modules/\.github/actions/node-access-gcp[[:space:]]*$ && ! "$entry" =~ uses:[[:space:]]+ai-workspace-infra/iac_modules/\.github/actions/node-access-gcp@[0-9a-f]{40}[[:space:]]*$ ]]; then
      fail "Vault node access must use an exact IaC owner path: $entry"
    fi
  done < <(awk '/uses:.*\.github\/actions\/(vault-node-stage|node-access-gcp)/' "$vault_workflow")
  while IFS= read -r entry; do
    if [[ "$entry" != *scripts/node_deploy/stage_plan.py* && "$entry" != *scripts/node_deploy/resolve_vault_server_declaration.py* ]]; then
      fail "Vault workflow local node_deploy code must be declaration or stage_plan only: $entry"
    fi
  done < <(awk '/(python3|bash)[[:space:]]+scripts\/node_deploy\//' "$vault_workflow")
fi
(( errors == 0 )) || exit 1
echo 'Active entry ownership verified; frozen bytes are debt, not UAT acceptance or deletion authorization.'
