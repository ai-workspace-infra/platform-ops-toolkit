#!/usr/bin/env bash
set -euo pipefail
umask 077
mode="${1:---check}"
[[ "$mode" == --check || "$mode" == --apply ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
yq -o=json '.' "$root/.github/config/uat-compute-cleanup-auth.yaml" > "$tmp/contract"
name="$(jq -er '.role_name' "$tmp/contract")"
jq -e '.role.bound_claims_type == "string" and .role.bound_claims.ref == "refs/heads/main" and
  .role.bound_claims.job_workflow_ref == "ai-workspace-infra/platform-ops-toolkit/.github/workflows/uat-daily-cleanup.yml@refs/heads/main" and
  (.policy.path | keys == ["kv/data/CICD/github-app/daily-snapshot","kv/data/uat/serverless/gcp"]) and
  all(.policy.path[]; .capabilities == ["read"])' "$tmp/contract" >/dev/null
jq '.role' "$tmp/contract" > "$tmp/role"
jq '.policy' "$tmp/contract" > "$tmp/policy"
if [[ "$mode" == --apply ]]; then
  vault policy write "$name" "$tmp/policy" >/dev/null
  vault write "auth/jwt/role/$name" "@$tmp/role" >/dev/null
fi
vault read -format=json "auth/jwt/role/$name" > "$tmp/current"
jq -e --slurpfile expected "$tmp/role" '.data as $actual |
  all($expected[0]|to_entries[] | select(.key != "token_ttl" and .key != "token_max_ttl");
    . as $field | $actual[$field.key] == $field.value) and
  $actual.token_ttl == 3600 and $actual.token_max_ttl == 3600' "$tmp/current" >/dev/null
vault read -format=json "sys/policies/acl/$name" > "$tmp/current-policy"
jq -e --slurpfile expected "$tmp/policy" '.data.policy | fromjson | . == $expected[0]' "$tmp/current-policy" >/dev/null
echo 'Exact main-only UAT cleanup OIDC role and read-only policy verified.'
