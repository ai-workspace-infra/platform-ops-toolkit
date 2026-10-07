#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${OWNER_RECEIPTS_DIR:?}" "${PROVIDER_OWNER_SHA:?}" "${PLAYBOOKS_OWNER_SHA:?}" "${RELEASE_TAG:?}" "${RELEASE_ENVIRONMENT:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
verdict=failure
summary() {
  {
    echo '## Serverless selected-stage verification'
    echo
    echo '| Stage | Result |'
    echo '| --- | --- |'
    for stage in SUPABASE CLOUD_RUN CLOUDFLARE FRONTEND_ROUTER EDGE_GATEWAY STATIC_PAGES SERVERLESS_DOMAINS; do
      variable="${stage}_RESULT"; printf '| %s | %s |\n' "$stage" "${!variable:-unknown}"
    done
    printf '| Verify | %s |\n' "$verdict"
    echo
    echo 'Provider receipts prove the selected operation completed; authenticated and business acceptance remain separate.'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
trap 'summary; rm -rf "$tmp"' EXIT
bool() { [[ "$1" == true || "$1" == false ]]; }
bool "${DEPLOYS_CLOUD_RUN:-}"; bool "${DEPLOYS_CLOUDFLARE:-}"; bool "${GUARDED_API_GATEWAY:-}"
[[ "$PROVIDER_OWNER_SHA" =~ ^[0-9a-f]{40}$ && "$PLAYBOOKS_OWNER_SHA" =~ ^[0-9a-f]{40}$ ]]
stage() {
  local variable="${1}_RESULT" result required="$2"
  result="${!variable:-}"
  if [[ "$required" == true ]]; then [[ "$result" == success ]];
  else [[ "$result" == skipped ]]; fi || { echo "::error::Selected stage $1 has no valid completion." >&2; return 1; }
}
stage SUPABASE true
[[ "${DATA_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] || { echo '::error::Validated data owner run is missing.' >&2; exit 1; }
stage CLOUD_RUN "$DEPLOYS_CLOUD_RUN"
for entry in CLOUDFLARE FRONTEND_ROUTER STATIC_PAGES SERVERLESS_DOMAINS; do stage "$entry" "$DEPLOYS_CLOUDFLARE"; done
edge=false
[[ "$DEPLOYS_CLOUDFLARE" != true || "$GUARDED_API_GATEWAY" == true ]] || edge=true
stage EDGE_GATEWAY "$edge"
files=()
files_count=0
if [[ -d "$OWNER_RECEIPTS_DIR" ]]; then
  find "$OWNER_RECEIPTS_DIR" -type f -name receipt.json -print0 > "$tmp/receipt-list"
  while IFS= read -r -d '' file; do files+=("$file"); files_count=$((files_count+1)); done < "$tmp/receipt-list"
fi
(( files_count <= 25 ))
if (( files_count )); then jq -s '.' "${files[@]}" > "$tmp/receipts"; else echo '[]' > "$tmp/receipts"; fi
jq -e --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
  --arg release "$RELEASE_TAG" --arg environment "$RELEASE_ENVIRONMENT" \
  --arg provider "$PROVIDER_OWNER_SHA" --arg playbooks "$PLAYBOOKS_OWNER_SHA" '
  type == "array" and all(.[];
    .schema == 1 and .accepted == true and .run_id == $run and .run_attempt == $attempt and
    .environment == $environment and .release_ref == $release and
    (if .scope == "provider-operation" then .owner_repository == "ai-workspace-infra/iac_modules" and .owner_commit == $provider
     elif .scope == "service-probe" then .owner_repository == "ai-workspace-infra/playbooks" and .owner_commit == $playbooks
     else false end)) and
  length == (unique_by([.scope,.operation,.target]) | length)' "$tmp/receipts" >/dev/null
require_targets() {
  jq -e --arg operation "$1" --argjson targets "$2" \
    '[.[] | select(.operation == $operation) | .target] | sort == ($targets|sort)' "$tmp/receipts" >/dev/null || {
      echo "::error::Valid owner receipts are missing for $1." >&2; return 1;
    }
}
if [[ "$DEPLOYS_CLOUD_RUN" == true ]]; then
  if [[ -n "${CLOUD_RUN_SERVICE:-}" ]]; then
    case "$CLOUD_RUN_SERVICE" in accounts|billing-service|content-service) ;; *) exit 2 ;; esac
    targets="$(jq -cn --arg service "$CLOUD_RUN_SERVICE" '[$service]')"
  else targets='["accounts","billing-service","content-service"]'; fi
  require_targets cloud-run "$targets"
fi
if [[ "$DEPLOYS_CLOUDFLARE" == true ]]; then
  case "${SERVERLESS_DNS_MODE:-}" in none|uat-records|prod-cutover) ;; *) exit 2 ;; esac
  require_targets domains "[\"$SERVERLESS_DNS_MODE\"]"
  require_targets ssr '["public","content","auth","console","workspace"]'
  require_targets frontend-router '["frontend-router"]'
  require_targets static-pages '["static-pages"]'
  [[ "$edge" == false ]] || require_targets edge-gateway '["auth","admin","core"]'
  for operation in public-chain frontend-assets brand-entry; do
    require_targets "$operation" "[\"$operation\"]"
  done
fi
verdict=success
echo 'Selected serverless stages and exact current-run owner receipts verified.'
