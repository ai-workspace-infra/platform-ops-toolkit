# UAT Accounts schema repair — 2026-10-04

## Scope and fixed artifact

This repairs the observed Serverless UAT schema lag, not a completed old-release
business acceptance. No PROD data synchronization, DNS changes, application
rebuild/redeploy, session copying, password reset, or billing-provider calls.

- Source tag: `daily-build-2026.10.04-r3`
- Accounts source: `c2c343fe2c91bb31e7f7f9b4fa60512a66e2b4c9`
- Expected serving digest: `sha256:4d69adfd3c71eced9ddf711bebed6a65e7ca1dca21bd572901c11cf3d02f0274`
- Reviewed migration: `2026092801_local_finance_ledger.up.sql`
- SQL SHA-256: `d066e223641b4eccbb65a00dce70f717b6dce02491d1d54edc1099baf2071433`
- Reviewed transition: `2026092703:false` → `2026092801:false`

The target creates five server-only empty financial tables and their protection
triggers. It does not convert existing subscriptions or payment history.
The wrapper previously rejected its `DROP TRIGGER IF EXISTS` statements. The
exception now requires BOTH this version and the exact reviewed whole-file hash;
other destructive payloads remain rejected.

## Execution and evidence contract

Use Serverless Orchestrator on the repair PR ref with these inputs:

```json
{
  "operation": "repair-schema",
  "vault_env_path": "uat",
  "target_domains": "web-saas",
  "cloud_provider": "gcp-cloud",
  "tag_ref": "daily-build-2026.10.04-r3",
  "apply_accounts_schema_migration": "true",
  "accounts_schema_expected_version": "2026092703",
  "accounts_schema_target_version": "2026092801",
  "accounts_schema_sha256": "d066e223641b4eccbb65a00dce70f717b6dce02491d1d54edc1099baf2071433",
  "deploy_cloud_run": "false",
  "deploy_cloudflare": "false",
  "skip_stripe_catalog": "true",
  "dns_mode": "none"
}
```

1. Verify Supabase and create a durable encrypted checkpoint. Required fields:
   `kv/uat/serverless/supabase:DATABASE_SESSION_POOLER_URL`,
   `kv/CICD/uat/iac_state:TF_STATE_{BUCKET,ACCESS_KEY,SECRET_KEY,REGION,ENDPOINT}`,
   `kv/uat/serverless/database-backup:BACKUP_ENCRYPTION_PASS`.
   Only the manifest is uploaded as a GitHub artifact; SQL is not.
2. Resolve the UAT project/region from GitOps, and read the serving Cloud Run
   service/revision using `kv/uat/serverless/gcp` WIF identity. Require stable
   100% traffic on the expected digest and compare its database connection with
   the UAT Vault target in memory. Require `/readyz` and `/api/ping` HTTP 200.
3. Capture all existing public table rows, except migration/checkpoint metadata,
   into keyed private HMACs. A private 0600 runner file holds only the key/counts/
   fingerprints, never source rows; it is not published as an artifact.
4. Run the pinned Accounts official `migratectl migrate` twice. Require exactly
   one clean target tracking row, prior prerequisites, and unchanged private
   users/subscriptions sentinel after both runs. An already-applied clean target
   is safe to retry; dirty, missing, multiple, or unexpected versions fail closed.
5. Recheck every preexisting table's private fingerprint/count, the same serving
   revision/digest, and health. Require RLS, eleven protection triggers, and
   validated financial PK/unique/FK constraints. Newly created financial tables
   must be empty. Publish only `uat-schema-repair-report.json` aggregates.

## Acceptance boundary

A schema repair success is NOT `upgrade_acceptance` and always records
`eligible_for_prod=false`. Admin and ordinary-user original-password login and
effective permissions remain user-owned manual verification. The subscription
sample was empty before this repair; it cannot become retention evidence by
creating a subscription afterwards. An authorized old application baseline and
nonempty pre-upgrade sample are still required for full business acceptance.

## Verification status

Local guard/contract tests and nine repair evidence unit tests pass. The PR also
runs the actual pinned official migration twice on PostgreSQL 17 with a disposable
nonempty subscription fixture. CI/run outcomes will be recorded after execution;
these fixtures never count as live UAT acceptance.
