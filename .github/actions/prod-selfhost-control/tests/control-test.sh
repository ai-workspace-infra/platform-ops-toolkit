#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
library="$root/.github/actions/prod-selfhost-control/lib.sh"
fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT
export LIBRARY="$library"
export GITHUB_REPOSITORY=ai-workspace-infra/platform-ops-toolkit
export GITHUB_REF=refs/tags/v2026.10.07-r8 GITHUB_SHA=347178891c74daf8becb583a1e7fbe8b80bfc256 GITHUB_RUN_ATTEMPT=1
export GITHUB_RUN_ID=123 GITHUB_EVENT_PATH="$fixtures/event.json"
export contract="$fixtures/contract.json"
yq -o=json '.' "$root/.github/config/prod-full-business.yaml" > "$contract"
passes=0
pass() { bash -euo pipefail -c 'source "$LIBRARY"; "$@"' _ "$@"; passes=$((passes+1)); }
reject() {
  if bash -euo pipefail -c 'source "$LIBRARY"; "$@"' _ "$@" >/dev/null 2>&1; then echo "Unexpected acceptance: $*" >&2; exit 1; fi
  passes=$((passes+1))
}
export CONTROL_MODE=full-business
pass validate_contract
jq '.transfer.database_cutover_approved=true' "$contract" > "$fixtures/bad.json"
saved="$contract"; export contract="$fixtures/bad.json"; reject validate_contract; export contract="$saved"
jq '.source.ready="false"' "$contract" > "$fixtures/bad.json"
export contract="$fixtures/bad.json"; reject validate_contract; export contract="$saved"
jq -n --arg sha "$GITHUB_SHA" '{inputs:{operation:"native-core-users-compare",vault_env_path:"prod",target_domains:"web-saas",
  cloud_provider:"gcp-cloud",cloud_account:"xworktech",target_domain_base:"svc.plus",dns_mode:"none",runner_type:"ubuntu-latest",offline_mode:"off",source_ref:$sha}}' > "$GITHUB_EVENT_PATH"
pass validate_input
GITHUB_RUN_ATTEMPT=2 reject validate_input
jq '.inputs.source_ref="main"' "$GITHUB_EVENT_PATH" > "$fixtures/wrong-event.json"
GITHUB_EVENT_PATH="$fixtures/wrong-event.json" reject validate_input

jq -n --arg sha "$GITHUB_SHA" '{id:123,run_attempt:1,event:"workflow_dispatch",head_sha:$sha,head_branch:"v2026.10.07-r8",
  repository:{full_name:"ai-workspace-infra/platform-ops-toolkit"},actor:{login:"dispatcher"},triggering_actor:{login:"dispatcher"}}' > "$fixtures/run.json"
echo '{"name":"prod","id":8,"protection_rules":[{"type":"required_reviewers","prevent_self_review":true,"reviewers":[{"id":1}]}]}' > "$fixtures/environment.json"
echo '[{"state":"approved","user":{"login":"reviewer"},"environments":[{"id":8,"name":"prod"}]}]' > "$fixtures/reviews.json"
jq '.independent_data_review_required=true' "$contract" > "$fixtures/review-contract.json"
export contract="$fixtures/review-contract.json"
pass validate_review "$fixtures/run.json" "$fixtures/environment.json" "$fixtures/reviews.json"
jq '.[0].user.login="dispatcher"' "$fixtures/reviews.json" > "$fixtures/self.json"
reject validate_review "$fixtures/run.json" "$fixtures/environment.json" "$fixtures/self.json"
jq '.protection_rules[0].prevent_self_review=false' "$fixtures/environment.json" > "$fixtures/no-protection.json"
reject validate_review "$fixtures/run.json" "$fixtures/no-protection.json" "$fixtures/reviews.json"
export contract="$saved"

jq --arg sha "$GITHUB_SHA" '. as $c | {stage:"native_schema_initialized",result:"initialized",environment:"prod",host:"web-saas-prod",
  database:"account",schema_initialized:true,schema_sha256:$c.initialization.schema_sha256,migration_version:$c.initialization.migration_version,
  business_tables:$c.initialization.business_tables,business_rows:0,accounts_commit:$c.initialization.accounts_commit,
  image_digest:$c.initialization.image_digest,writers_paused:true,independent_disk_verified:true,database_cutover_approved:false}' "$contract" > "$fixtures/initialized.json"
pass validate_receipt initialized "$fixtures/initialized.json"
jq '.business_rows=1' "$fixtures/initialized.json" > "$fixtures/seeded.json"
reject validate_receipt initialized "$fixtures/seeded.json"
jq '. as $c | {stage:"native_billing_schema_upgraded",result:"upgraded",environment:"prod",host:"web-saas-prod",database:"account",
  business_rows:0,target_version:2026100701,migration_version:2026100701,billing_commit:$c.billing.commit,migration_sha256:$c.billing.migration_sha256,
  accounts_commit:$c.initialization.accounts_commit,image_digest:$c.initialization.image_digest,business_tables:$c.transfer.business_tables,
  writers_paused:true,independent_disk_verified:true,database_cutover_approved:false}' "$contract" > "$fixtures/billing.json"
pass validate_receipt billing "$fixtures/billing.json"
jq '.migration_sha256="wrong"' "$fixtures/billing.json" > "$fixtures/wrong-billing.json"
reject validate_receipt billing "$fixtures/wrong-billing.json"
jq '. as $c | ("a"*64) as $hash | {stage:"full_business_baseline_copied",result:"copied",environment:"prod",host:"web-saas-prod",database:"account",
  migration_version:2026100701,business_tables:$c.transfer.business_tables,format:1,accounts_commit:$c.transfer.accounts_commit,
  image_digest:$c.transfer.image_digest,schema_sha256:$c.initialization.schema_sha256,billing_schema_sha256:$c.billing.migration_sha256,
  batch_size:1000,source_identity_sha256:$hash,source_read_only:true,full_business_equal:true,target_writes:true,source_writers_paused:false,
  final_catchup_complete:false,source_snapshot_sha256:$hash,source_catalog_sha256:$hash,source_table_count:53,user_count:1,
  tables:($c.transfer.business_tables | map({key:.,value:{rows:1,sha256:$hash}}) | from_entries),
  core_users:({count:1,email_sha256:$hash,password_hash_sha256:$hash,email_proxy_sha256:$hash} as $proof | {source:$proof,target:$proof}),
  snapshot_started_at:"2026-10-07T01:00:00.000Z",completed_at:"2026-10-07T01:30:00.000Z",
  writers_paused:true,independent_disk_verified:true,database_cutover_approved:false}' "$contract" > "$fixtures/copy.json"
pass validate_receipt copy "$fixtures/copy.json"
jq 'del(.tables.sessions)' "$fixtures/copy.json" > "$fixtures/missing-table.json"
reject validate_receipt copy "$fixtures/missing-table.json"
jq '.core_users.target.email_proxy_sha256=("b"*64)' "$fixtures/copy.json" > "$fixtures/core-mismatch.json"
reject validate_receipt copy "$fixtures/core-mismatch.json"
jq '.completed_at="2026-10-07T01:30:00.500Z"' "$fixtures/copy.json" > "$fixtures/slow.json"
reject validate_receipt copy "$fixtures/slow.json"

printf '{}\n' > "$fixtures/receipt.json"
(cd "$fixtures" && zip -q receipt.zip receipt.json)
jq --arg digest "sha256:$(shasum -a 256 "$fixtures/receipt.zip" | awk '{print $1}')" '.standby.artifact_digest=$digest' "$contract" > "$fixtures/archive-contract.json"
export contract="$fixtures/archive-contract.json"
pass safe_archive "$fixtures/receipt.zip" standby receipt.json 65536
reject safe_archive "$fixtures/receipt.zip" standby other.json 65536
reject safe_archive "$fixtures/receipt.zip" standby receipt.json 1
ln -s receipt.json "$fixtures/link.json"
(cd "$fixtures" && zip -y -q link.zip link.json)
jq --arg digest "sha256:$(shasum -a 256 "$fixtures/link.zip" | awk '{print $1}')" '.standby.artifact_digest=$digest' "$contract" > "$fixtures/link-contract.json"
export contract="$fixtures/link-contract.json"
reject safe_archive "$fixtures/link.zip" standby link.json 65536
printf 'PASS: %s PROD shell evidence gates and falsifiable rejection cases\n' "$passes"
