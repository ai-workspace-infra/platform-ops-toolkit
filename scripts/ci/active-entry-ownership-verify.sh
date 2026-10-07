#!/usr/bin/env bash
set -euo pipefail
root="${1:-$(pwd)}"
registry="${2:-$root/scripts/ci/control-plane-legacy.yaml}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
yq -o=json '.' "$registry" > "$tmp/registry"
jq -e '.schema == 1 and (.legacy | type == "array")' "$tmp/registry" >/dev/null
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
  if rg -q "$pattern" "$tmp/source"; then
    jq -e --arg path "$relative" 'any(.legacy[]; .path == $path)' "$tmp/registry" >/dev/null ||
      fail "Execution must move to an owner: $relative"
  fi
done < <(git -C "$root" ls-files -co --exclude-standard .github/scripts .github/actions scripts/serverless_uat | sort -u)
# Scan direct callers as well as their frozen implementation. Thin wrappers
# cannot remain the formal route after their owner caller has been switched.
while IFS= read -r entry; do
  if rg -Fql -- "$entry" "$root/.github/workflows"; then fail "Retired execution route remains active: $entry"; fi
done < <(jq -r '.retired_workflow_entries[]' "$tmp/registry")
(( errors == 0 )) || exit 1
echo 'Active entry ownership verified; frozen bytes are debt, not UAT acceptance or deletion authorization.'
