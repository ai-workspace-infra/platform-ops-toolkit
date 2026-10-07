#!/usr/bin/env bash
# Source-only library. No provider, host, database or service commands.

control_error() { echo '::error::PROD control gate stopped; private API/artifact output withheld.' >&2; return 1; }
digest() { shasum -a 256 "$1" | awk '{print $1}'; }
check_json() { jq -e "$@" >/dev/null 2>&1 || control_error; }

validate_input() {
  check_json --arg mode "$CONTROL_MODE" --arg ref "$GITHUB_REF" --arg sha "$GITHUB_SHA" \
    --arg repository "$GITHUB_REPOSITORY" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" '
    .inputs as $i |
    $repository == "ai-workspace-infra/platform-ops-toolkit" and
    ($ref | test("^refs/tags/v[0-9][0-9.r-]*$")) and ($sha | test("^[0-9a-f]{40}$")) and
    $i.vault_env_path == "prod" and $i.target_domains == "web-saas" and
    $i.cloud_provider == "gcp-cloud" and $i.cloud_account == "xworktech" and
    $i.target_domain_base == "svc.plus" and $i.runner_type == "ubuntu-latest" and $i.offline_mode == "off" and
    (["", "https://vault.svc.plus"] | index($i.vault_addr // "")) != null and
    (["", $sha] | index($i.source_ref // "")) != null and
    (if $mode == "availability" then
       (["deploy", "deploy+migrate", "native-availability"] | index($i.operation)) != null
     else $i.dns_mode == "none" and (($i.deploy_tag // "") == "") and
       (if $mode == "standby" then $i.operation == "native-standby"
        elif $mode == "initialization" then $attempt == "1" and (["native-init-plan", "native-init"] | index($i.operation)) != null
        elif $mode == "billing" then $attempt == "1" and (["native-billing-plan", "native-billing"] | index($i.operation)) != null
        elif $mode == "full-business" then $attempt == "1" and
          (["native-business-plan", "native-business-copy", "native-business-compare", "native-core-users", "native-core-users-compare"] | index($i.operation)) != null
        else false end) end)' "$GITHUB_EVENT_PATH"
}

validate_contract() {
  check_json --arg mode "$CONTROL_MODE" '
    def sha: type == "string" and test("^[0-9a-f]{40}$");
    def hash: type == "string" and test("^[0-9a-f]{64}$");
    def image_digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def integer: type == "number" and floor == .;
    def initialization:
      .schema == 1 and .environment == "prod" and .host == "web-saas-prod" and .database == "account" and
      (.accounts_commit | sha) and .image == ("ghcr.io/ai-workspace-services/accounts:sha-" + .accounts_commit) and
      (.image_digest | image_digest) and (.schema_sha256 | hash) and
      (.migration_version | integer and . > 0) and .business_table_count == 52 and
      (.business_tables | type == "array" and length == 52 and . == (sort | unique) and
        all(.[]; type == "string" and test("^[a-z][a-z0-9_]*$")));
    def billing:
      . as $c | .billing as $b |
      ($c.initialization | initialization) and
      $b.format == 1 and $b.owner == "ai-workspace-services/billing-service" and ($b.commit | sha) and
      $b.migration_file == "sql/migrations/2026100701_cloud_vendor_costs.up.sql" and ($b.migration_sha256 | hash) and
      $b.expected_schema_version == $c.initialization.migration_version and $b.expected_schema_version == 2026100601 and
      $b.target_schema_version == 2026100701 and $b.business_tables == ["cloud_vendor_costs"] and
      $b.no_business_seeds == true and $b.database_cutover_approved == false;
    if $mode == "standby" or $mode == "availability" then true else
      . as $c | .initialization as $i | .transfer as $t | .source as $s |
      .schema == 1 and (.independent_data_review_required | type == "boolean") and
      ([.gitops_commit, .iac_commit, .playbooks_commit] | all(.[]; sha)) and
      (if $mode == "initialization" then .scope == "prod-native-init-only" and ($i | initialization)
       elif $mode == "billing" then .scope == "prod-native-billing-only" and billing
       elif $mode == "full-business" then .scope == "prod-full-business-only" and billing and
         $i.migration_version == 2026100601 and $i.schema_sha256 == "842cef3beb98ef819dc854ecdf5f85683233641a0cd85a9156b30ad59f7e0206" and
         .billing.migration_sha256 == "a7133f3ef2ea9013a055cfd1442a7488d2b837f289e0f5d9b61624d4fde9bc53" and
         $t.schema == 1 and $t.environment == "prod" and $t.host == "web-saas-prod" and $t.database == "account" and
         ($t.accounts_commit | sha) and $t.image == ("ghcr.io/ai-workspace-services/accounts:sha-" + $t.accounts_commit) and
         ($t.image_digest | image_digest) and $t.schema_sha256 == $i.schema_sha256 and
         $t.billing_schema_sha256 == .billing.migration_sha256 and $t.migration_version == 2026100701 and
         $t.batch_size == 1000 and $t.business_tables == (($i.business_tables + ["cloud_vendor_costs"]) | sort) and
         $t.database_cutover_approved == false and $s.role == "serverless_supabase" and
         (["direct", "session_pooler"] | index($s.endpoint)) != null and $s.tls_required == true and
         ($s.project_ref | type == "string" and test("^[a-z0-9]{20}$")) and
         $s.direction == "prod-supabase-to-prod-selfhost" and ($s.ready | type == "boolean") and
         (if $s.ready then ($s.identity_sha256 | hash) else $s.identity_sha256 == null end)
       else false end)
    end' "$contract"
}

validate_review() {
  check_json --arg run_id "$GITHUB_RUN_ID" --arg sha "$GITHUB_SHA" --arg ref "${GITHUB_REF#refs/tags/}" '
    .id == ($run_id | tonumber) and .run_attempt == 1 and .event == "workflow_dispatch" and
    .head_sha == $sha and .head_branch == $ref and .repository.full_name == "ai-workspace-infra/platform-ops-toolkit"' "$1"
  if jq -e '.independent_data_review_required == true' "$contract" >/dev/null; then
    check_json '.name == "prod" and any(.protection_rules[]?;
      .type == "required_reviewers" and .prevent_self_review == true and (.reviewers | length) > 0)' "$2"
    check_json --slurpfile run "$1" --slurpfile environment "$2" '
      . as $reviews | [$run[0].actor.login, $run[0].triggering_actor.login] | map(select(. != null)) as $actors |
      ($actors | length) > 0 and any($reviews[]?; .state == "approved" and
        (.user.login | type == "string" and length > 0) and
        (.user.login as $approver | ($actors | index($approver)) == null) and
        any(.environments[]?; .id == $environment[0].id and .name == "prod"))' "$3"
  fi
}

validate_parent() {
  local kind="$1" run="$2" workflow="$3" artifact="$4" key accepted name limit workflow_path
  case "$kind" in
    resource) key=resource; accepted=resource_accepted; name=gcp-prod-web-saas-inventory; limit=2097152; workflow_path=.github/workflows/gcp-iac-pipeline.yml ;;
    standby) key=standby; accepted=standby_accepted; name=prod-native-standby-receipt; limit=65536; workflow_path=.github/workflows/selfhost-orchestrator.yml ;;
    initialized) key=initialized; accepted=initialization_accepted; name=prod-native-init-receipt; limit=65536; workflow_path=.github/workflows/selfhost-orchestrator.yml ;;
    billing) key=upgraded; accepted=billing_accepted; name=prod-native-billing-receipt; limit=65536; workflow_path=.github/workflows/selfhost-orchestrator.yml ;;
    copy) key=copied; accepted=copy_accepted; name=prod-full-business-receipt; limit=65536; workflow_path=.github/workflows/selfhost-orchestrator.yml ;;
    *) return 1 ;;
  esac
  check_json --arg key "$key" --arg accepted "$accepted" '
    def positive_integer: type == "number" and floor == . and . > 0;
    .[$key] as $p | .[$accepted] == true and ($p.run_id | positive_integer) and $p.run_attempt == 1 and
    ($p.artifact_id | positive_integer) and ($p.toolkit_commit | type == "string" and test("^[0-9a-f]{40}$")) and
    ($p.release_tag | type == "string" and test("^v[0-9][0-9.r-]*$")) and
    ($p.artifact_digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))' "$contract"
  check_json --slurpfile c "$contract" --arg key "$key" '
    $c[0][$key] as $p | .id == $p.run_id and .run_attempt == $p.run_attempt and
    .repository.full_name == "ai-workspace-infra/platform-ops-toolkit" and .event == "workflow_dispatch" and
    .status == "completed" and .conclusion == "success" and .head_sha == $p.toolkit_commit and .head_branch == $p.release_tag' "$run"
  check_json --slurpfile run "$run" --arg path "$workflow_path" '.id == $run[0].workflow_id and .path == $path' "$workflow"
  check_json --slurpfile c "$contract" --arg key "$key" --arg name "$name" --argjson limit "$limit" '
    $c[0][$key] as $p | .id == $p.artifact_id and .name == $name and .expired == false and
    .workflow_run.id == $p.run_id and .workflow_run.head_sha == $p.toolkit_commit and
    .digest == $p.artifact_digest and (.size_in_bytes | type == "number" and . > 0 and . <= $limit)' "$artifact"
}

# Inspect metadata before streaming any member. Exact names exclude traversal;
# unzip -p writes bytes only, never archive permissions or filesystem links.
safe_archive() {
  local archive="$1" key="$2" expected_names="$3" maximum="$4" names metadata
  [[ $(wc -c < "$archive") -le "$maximum" ]] || return 1
  [[ "sha256:$(digest "$archive")" == "$(jq -er --arg key "$key" '.[$key].artifact_digest' "$contract")" ]] || return 1
  names=$(zipinfo -1 "$archive" 2>/dev/null) || return 1
  [[ -n "$names" && $(printf '%s\n' "$names" | sort | uniq -d | wc -l) -eq 0 ]] || return 1
  while IFS= read -r name; do
    [[ " $expected_names " == *" $name "* ]] || return 1
  done <<< "$names"
  metadata=$(zipinfo -l "$archive" 2>/dev/null) || return 1
  printf '%s\n' "$metadata" | awk -v maximum="$maximum" -v expected="$(printf '%s\n' "$names" | wc -l)" '
    $1 ~ /^[-?ldbcps]/ && NF >= 9 {
      if ($1 ~ /^[ldbcps]/ || $4 !~ /^[0-9]+$/) exit 1;
      bytes += $4; count++;
    }
    END { if (count != expected || bytes > maximum) exit 1 }' || return 1
}

stream_member() {
  local archive="$1" name="$2" output="$3" maximum="$4"
  unzip -p "$archive" "$name" 2>/dev/null | head -c "$((maximum + 1))" > "$output" || return 1
  [[ $(wc -c < "$output") -le "$maximum" ]] || return 1
  chmod 600 "$output"
}

validate_receipt() {
  local kind="$1" file="$2"
  check_json --slurpfile c "$contract" --arg kind "$kind" '
    def hash: type == "string" and test("^[0-9a-f]{64}$");
    def integer: type == "number" and floor == .;
    def epoch: . as $time | ($time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) +
      (if ($time | contains(".")) then ($time | capture("\\.(?<fraction>[0-9]+)Z$").fraction | "0." + . | tonumber) else 0 end);
    $c[0] as $c | $c.initialization as $i | $c.billing as $b | $c.transfer as $t |
    . as $r | .environment == "prod" and .host == "web-saas-prod" and
    .writers_paused == true and .independent_disk_verified == true and .database_cutover_approved == false and
    (if $kind == "standby" then
       .stage == "database_standby" and .gitops_commit == $c.gitops_commit and .postgres_major == 17 and .schema_initialized == false
     elif $kind == "initialized" then
       .stage == "native_schema_initialized" and .result == "initialized" and .database == "account" and
       .schema_initialized == true and .schema_sha256 == $i.schema_sha256 and .migration_version == $i.migration_version and
       .business_tables == $i.business_tables and .business_rows == 0 and .accounts_commit == $i.accounts_commit and .image_digest == $i.image_digest
     elif $kind == "billing" then
       .stage == "native_billing_schema_upgraded" and .result == "upgraded" and .database == "account" and
       .business_rows == 0 and .target_version == 2026100701 and .migration_version == 2026100701 and
       .billing_commit == $b.commit and .migration_sha256 == $b.migration_sha256 and
       .accounts_commit == $i.accounts_commit and .image_digest == $i.image_digest and .business_tables == $t.business_tables
     elif $kind == "copy" then
       .stage == "full_business_baseline_copied" and .result == "copied" and .database == "account" and
       .migration_version == 2026100701 and .business_tables == $t.business_tables and .format == 1 and
       .accounts_commit == $t.accounts_commit and .image_digest == $t.image_digest and .schema_sha256 == $i.schema_sha256 and
       .billing_schema_sha256 == $b.migration_sha256 and .batch_size == 1000 and
       (if $c.source.identity_sha256 != null then .source_identity_sha256 == $c.source.identity_sha256 else (.source_identity_sha256 | hash) end) and
       .source_read_only == true and .full_business_equal == true and .target_writes == true and
       .source_writers_paused == false and .final_catchup_complete == false and
       ([.source_snapshot_sha256, .source_catalog_sha256] | all(.[]; hash)) and
       (.source_table_count | integer and . >= 44 and . <= 53) and (.user_count | integer and . > 0) and
       (.tables | type == "object" and keys == $t.business_tables and all(.[];
         keys == ["rows", "sha256"] and (.rows | integer and . >= 0) and (.sha256 | hash))) and
       .tables.users.rows == .user_count and
       (.core_users | type == "object" and keys == ["source", "target"] and .source == .target and
         all(.[]; keys == ["count", "email_proxy_sha256", "email_sha256", "password_hash_sha256"] and
           (.count | integer and . > 0) and ([.email_sha256, .password_hash_sha256, .email_proxy_sha256] | all(.[]; hash)))) and
       .core_users.source.count == .user_count and
       ([.snapshot_started_at, .completed_at] | all(.[]; type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$"))) and
       ((.completed_at | epoch) - (.snapshot_started_at | epoch) | . >= 0 and . <= 1800)
     else false end)' "$file"
}
