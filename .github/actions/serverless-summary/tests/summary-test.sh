#!/usr/bin/env bash
set -euo pipefail
action="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export OWNER_RECEIPTS_DIR="$tmp/receipts" GITHUB_STEP_SUMMARY="$tmp/summary"
export PROVIDER_OWNER_SHA=1111111111111111111111111111111111111111 PLAYBOOKS_OWNER_SHA=2222222222222222222222222222222222222222
export RELEASE_TAG=v2026.10.07 RELEASE_ENVIRONMENT=uat GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 DATA_RUN_ID=456
export DEPLOYS_CLOUD_RUN=true DEPLOYS_CLOUDFLARE=false GUARDED_API_GATEWAY=false CLOUD_RUN_SERVICE=accounts
export SUPABASE_RESULT=success CLOUD_RUN_RESULT=success CLOUDFLARE_RESULT=skipped FRONTEND_ROUTER_RESULT=skipped EDGE_GATEWAY_RESULT=skipped STATIC_PAGES_RESULT=skipped SERVERLESS_DOMAINS_RESULT=skipped SERVERLESS_DNS_MODE=none
fixture() {
  rm -rf "$OWNER_RECEIPTS_DIR"; mkdir -p "$OWNER_RECEIPTS_DIR/accounts"; rm -f "$GITHUB_STEP_SUMMARY"
  jq -n --arg owner "$PROVIDER_OWNER_SHA" --arg release "$RELEASE_TAG" \
    '{schema:1,accepted:true,scope:"provider-operation",owner_repository:"ai-workspace-infra/iac_modules",
      owner_commit:$owner,run_id:"123",run_attempt:"1",environment:"uat",release_ref:$release,operation:"cloud-run",target:"accounts"}' > "$OWNER_RECEIPTS_DIR/accounts/receipt.json"
}
run() { bash "$action/verify.sh" > "$tmp/log" 2>&1; }
reject() { if run; then echo "Unexpected acceptance: $1" >&2; exit 1; fi; rg -q '\| Verify \| failure \|' "$GITHUB_STEP_SUMMARY"; ! rg -q '\| Verify \| success \|' "$GITHUB_STEP_SUMMARY"; echo "PASS reject $1"; }
fixture; run; rg -q '\| Verify \| success \|' "$GITHUB_STEP_SUMMARY"; echo 'PASS selected service with exact owner receipt'
fixture; CLOUD_RUN_RESULT=unknown reject unknown
fixture; CLOUD_RUN_RESULT= reject empty
fixture; CLOUD_RUN_RESULT=skipped reject 'selected stage skipped'
fixture; rm "$OWNER_RECEIPTS_DIR/accounts/receipt.json"; reject 'missing receipt'
fixture; jq '.run_id="122"' "$OWNER_RECEIPTS_DIR/accounts/receipt.json" > "$tmp/new"; mv "$tmp/new" "$OWNER_RECEIPTS_DIR/accounts/receipt.json"; reject 'different run'
fixture; jq '.owner_commit="3333333333333333333333333333333333333333"' "$OWNER_RECEIPTS_DIR/accounts/receipt.json" > "$tmp/new"; mv "$tmp/new" "$OWNER_RECEIPTS_DIR/accounts/receipt.json"; reject 'different owner SHA'
fixture; mkdir "$OWNER_RECEIPTS_DIR/duplicate"; cp "$OWNER_RECEIPTS_DIR/accounts/receipt.json" "$OWNER_RECEIPTS_DIR/duplicate/receipt.json"; reject 'duplicate receipt'
fixture; DATA_RUN_ID= reject 'missing validated data owner run'
fixture; CLOUD_RUN_SERVICE=content-service reject 'different selected service'
fixture; DEPLOYS_CLOUDFLARE=true CLOUDFLARE_RESULT=success FRONTEND_ROUTER_RESULT=success EDGE_GATEWAY_RESULT=success STATIC_PAGES_RESULT=success SERVERLESS_DOMAINS_RESULT=success reject 'missing selected Cloudflare receipts'
fixture
for pair in 'ssr public' 'ssr content' 'ssr auth' 'ssr console' 'ssr workspace' 'frontend-router frontend-router' 'static-pages static-pages' 'domains none' 'edge-gateway auth' 'edge-gateway admin' 'edge-gateway core' 'public-chain public-chain' 'frontend-assets frontend-assets' 'brand-entry brand-entry'; do
  operation="${pair%% *}"; target="${pair#* }"; scope=provider-operation; owner="$PROVIDER_OWNER_SHA"; repository=ai-workspace-infra/iac_modules
  case "$operation" in public-chain|frontend-assets|brand-entry) scope=service-probe; owner="$PLAYBOOKS_OWNER_SHA"; repository=ai-workspace-infra/playbooks ;; esac
  mkdir -p "$OWNER_RECEIPTS_DIR/$operation-$target"
  jq --arg operation "$operation" --arg target "$target" --arg scope "$scope" --arg owner "$owner" --arg repository "$repository" \
    '.operation=$operation | .target=$target | .scope=$scope | .owner_commit=$owner | .owner_repository=$repository' \
    "$OWNER_RECEIPTS_DIR/accounts/receipt.json" > "$OWNER_RECEIPTS_DIR/$operation-$target/receipt.json"
done
DEPLOYS_CLOUDFLARE=true CLOUDFLARE_RESULT=success FRONTEND_ROUTER_RESULT=success EDGE_GATEWAY_RESULT=success STATIC_PAGES_RESULT=success SERVERLESS_DOMAINS_RESULT=success run
echo 'PASS full selected Cloudflare/Cloud Run owner receipt set'
fixture; jq '.run_attempt="2"' "$OWNER_RECEIPTS_DIR/accounts/receipt.json" > "$tmp/new"; mv "$tmp/new" "$OWNER_RECEIPTS_DIR/accounts/receipt.json"; reject 'different attempt'
fixture; jq '.accepted=false' "$OWNER_RECEIPTS_DIR/accounts/receipt.json" > "$tmp/new"; mv "$tmp/new" "$OWNER_RECEIPTS_DIR/accounts/receipt.json"; reject 'unaccepted receipt'
fixture; jq '.environment="prod"' "$OWNER_RECEIPTS_DIR/accounts/receipt.json" > "$tmp/new"; mv "$tmp/new" "$OWNER_RECEIPTS_DIR/accounts/receipt.json"; reject 'different environment'
fixture; rm -rf "$OWNER_RECEIPTS_DIR"; DEPLOYS_CLOUD_RUN=false CLOUD_RUN_RESULT=skipped run; echo 'PASS unselected stages skipped'
echo '16 summary checks passed; unknown/empty/missing receipts cannot pass.'
