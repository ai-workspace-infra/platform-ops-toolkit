# Synthetic evidence for isolated contract tests, never a UAT artifact writer.
. as $manifest |
. + {upgrade_acceptance: {
  schema: 1, environment: "uat", snapshot_tag: $manifest.snapshot_tag,
  images: ($manifest.images | sort_by(.service)),
  baseline: {snapshot_tag: "daily-build-2026.09.29-r1", existing_users: 2, subscriptions: 1},
  migration: {before_version: 2026090802, before_dirty: false,
    expected_version: 2026092801, actual_version: 2026092801, dirty: false},
  gates: {
    smooth_upgrade: {
      status: "passed", data_and_relations_preserved: true, application_healthy: true,
      runtime_digest_verified: true, migration_idempotent: true,
      evidence_urls: ["https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/4242"]
    },
    original_user_login: {
      status: "passed", uat_login_executed: true, original_password_compatible: true,
      permissions_verified: true,
      evidence_urls: ["https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/4242"]
    },
    subscriptions_preserved: {
      status: "passed", plan_status_validity_entitlements_unchanged: true,
      api_or_page_readable: true, quota_not_reset: true, no_duplicate_charge: true,
      evidence_urls: ["https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/4242"]
    }
  }
}}
