#!/usr/bin/env python3
"""Offline contract rehearsal. Uses synthetic receipts; never contacts a DB/cloud."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "upgrade_pipeline", ROOT / ".github/scripts/environment-upgrade/pipeline.py")
pipeline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pipeline)


def request(environment="uat", mode="upgrade"):
    tag = "daily-build-2026.10.04-r3" if environment == "uat" else "v2026.10.04-r3"
    return {"DEPLOY_ENV": environment, "UPGRADE_MODE": mode, "RELEASE_TAG": tag,
            "EXPECTED_SCHEMA_VERSION": "2026092801", "TARGET_SCHEMA_VERSION": "2026100401",
            "MIGRATION_SHA256": "a" * 64, "CANDIDATE_RUN_ID": "1234", "REHEARSAL_RUN_ID": "5678",
            "GITHUB_REF": "refs/heads/main" if environment == "uat" else "refs/tags/" + tag,
            "GITHUB_RUN_ID": "5678"}


def candidate(environment="uat", mode="upgrade"):
    value = pipeline.inputs(request(environment, mode))
    value.update(evidence_kind="live_candidate", run_id="5678", uat_run_id="1234",
                 images=[{"service": service, "digest": "sha256:" + "b" * 64}
                         for service in pipeline.SERVICES])
    return value


def receipts(value):
    base = {"schema": 1, "environment": value["environment"], "status": "passed",
            "candidate_sha256": pipeline.identity(value)}
    old = {service: "sha256:" + "c" * 64 for service in pipeline.SERVICES}
    stages = {
        "preflight": dict(clean=True, old_application_healthy=True, permissions_baseline_captured=True,
                          ledger_baseline_captured=True, schema_version=value["expected_schema_version"],
                          existing_users=2, subscriptions=1, rollback_digests=old),
        "backup": dict(encrypted=True, durable=True, download_verified=True, isolated_restore_verified=True,
                       restored_data_matches=True, checkpoint_id="checkpoint_5678",
                       schema_version=value["expected_schema_version"], source_database_identity="d" * 64,
                       restore_database_identity="e" * 64, backup_backend="selfhost-web-saas",
                       backup_environment=value["environment"], backup_host_identity="f" * 64,
                       fallback_runtime_preserved=True, fallback_database_preserved=True,
                       gitops_backup_host_verified=True),
        "migration": dict(dirty_false=True, database_lock_held=True, bounded_lock_wait=True,
                          bounded_execution=True, reviewed_additive_sql=True, old_application_compatible=True,
                          data_preserved=True, idempotent=True, before_version=value["expected_schema_version"],
                          after_version=value["target_schema_version"], migration_sha256=value["migration_sha256"],
                          checkpoint_id="checkpoint_5678"),
        "promotion": dict(same_digest=True, no_rebuild=True, no_shared_bootstrap=True, no_data_sync=True,
                          fallback_preserved=True, running_digests=pipeline.digests(value), rollback_digests=old),
        "verification": dict(original_password_login=True, permissions_preserved=True,
                             subscription_entitlements_preserved=True, quota_preserved=True,
                             financial_ledger_preserved=True, usage_ledger_preserved=True,
                             no_real_payment_or_refund=True, healthy=True, runtime_digest_verified=True,
                             running_digests=pipeline.digests(value), schema_version=value["target_schema_version"],
                             dirty=False),
    }
    stages["rollback"] = dict(application_only=True, no_database_restore=True, schema_retained=True,
                              healthy=True, old_application_compatible=True,
                              original_password_login=True, permissions_preserved=True,
                              subscription_entitlements_preserved=True, quota_preserved=True,
                              financial_ledger_preserved=True, usage_ledger_preserved=True,
                              no_real_payment_or_refund=True, runtime_digest_verified=True,
                              running_digests=old, schema_version=value["target_schema_version"], dirty=False)
    stages["repromotion"] = dict(stages["promotion"])
    stages["final_verification"] = dict(stages["verification"])
    return {phase: dict(base, phase=phase, **fields) for phase, fields in stages.items()}


class EnvironmentUpgradeTests(unittest.TestCase):
    def resolved(self, environment, mutate=None, annotated=True, actual_sha="f" * 40, mode="upgrade",
                 mutate_rehearsal=None, mutate_rehearsal_run=None):
        env = request(environment, mode)
        env.update(GITHUB_REPOSITORY="ai-workspace-infra/platform-ops-toolkit", GITHUB_SHA="f" * 40)
        snapshot = "daily-build-2026.10.04-r3"
        base = {"schema": 1, "environment": "uat", "snapshot_tag": snapshot, "uat_run_id": "1234",
                "images": [{"service": service, "digest": "sha256:" + "b" * 64,
                            "source_sha": "c" * 40, "source_repository": "ai-workspace-services/" + service,
                            "tag": snapshot, "image": "asia-east1-docker.pkg.dev/open-platform-uat/serverless/" + service}
                           for service in sorted(pipeline.SERVICES)]}
        manifest = json.loads(subprocess.check_output(
            ["jq", "-f", str(ROOT / ".github/scripts/tests/fixtures/uat-upgrade-acceptance.jq")],
            input=json.dumps(base).encode()))
        manifest["migration_sha256"] = env["MIGRATION_SHA256"]
        manifest["upgrade_acceptance"]["migration"].update(
            before_version=int(env["EXPECTED_SCHEMA_VERSION"]), before_dirty=False,
            expected_version=int(env["TARGET_SCHEMA_VERSION"]), actual_version=int(env["TARGET_SCHEMA_VERSION"]), dirty=False)
        if mutate:
            mutate(manifest)
        run = {"id": 1234, "path": ".github/workflows/hybrid-orchestrator.yml", "head_branch": "main",
               "event": "workflow_dispatch", "status": "completed", "conclusion": "success",
               "repository": {"full_name": env["GITHUB_REPOSITORY"]}}
        def fake_command(args):
            if args[1:3] == ["run", "download"]:
                if args[-3].startswith("environment-data-evidence"):
                    value = candidate(mode="rehearsal")
                    value["images"] = manifest["images"]
                    proof = {"schema": 1, "status": "passed", "candidate": value,
                             "candidate_sha256": pipeline.identity(value), "receipts": receipts(value)}
                    if mutate_rehearsal:
                        mutate_rehearsal(proof)
                    Path(args[-1], "uat-rehearsal-qualification.json").write_text(json.dumps(proof))
                    return ""
                Path(args[-1], "uat-artifact-manifest.json").write_text(json.dumps(manifest))
                return ""
            endpoint = args[-1]
            if endpoint.endswith("/environments/prod"):
                return json.dumps({"protection_rules": [{"type": "required_reviewers",
                                                          "prevent_self_review": True,
                                                          "reviewers": [{"reviewer": {"login": "reviewer"}}]}]})
            if "/actions/runs/" in endpoint:
                if endpoint.endswith("/5678"):
                    record = dict(run, id=5678, path=".github/workflows/environment-data-operations.yml")
                    if mutate_rehearsal_run:
                        mutate_rehearsal_run(record)
                    return json.dumps(record)
                return json.dumps(run)
            if "/git/ref/tags/" in endpoint:
                return json.dumps({"object": {"type": "tag" if annotated else "commit", "sha": "a" * 40}})
            if "/git/tags/" in endpoint:
                return json.dumps({"object": {"type": "commit", "sha": actual_sha}})
            self.fail("unexpected command")
        with patch.object(pipeline, "command", side_effect=fake_command):
            return pipeline.resolve_candidate(env)

    def test_uat_can_generate_first_acceptance(self):
        value = self.resolved("uat", lambda m: m.pop("upgrade_acceptance"))
        self.assertEqual(len(value["images"]), 3)

    def test_prod_resolves_bound_accepted_artifacts(self):
        self.assertEqual(self.resolved("prod")["release_tag"], "v2026.10.04-r3")

    def test_prod_rejects_missing_business_or_checksum_evidence(self):
        for field in ("upgrade_acceptance", "migration_sha256"):
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                self.resolved("prod", lambda m: m.pop(field))

    def test_prod_rejects_lightweight_or_moved_tag(self):
        with self.assertRaises(pipeline.Blocked):
            self.resolved("prod", annotated=False)
        with self.assertRaises(pipeline.Blocked):
            self.resolved("prod", actual_sha="e" * 40)

    def test_prod_requires_independent_environment_approval(self):
        env = request("prod")
        env.update(GITHUB_REPOSITORY="ai-workspace-infra/platform-ops-toolkit", GITHUB_SHA="f" * 40)
        def fake_command(args):
            if args[-1].endswith("/environments/prod"):
                return json.dumps({"protection_rules": []})
            self.fail("PROD source lookup happened before approval preflight")
        with patch.object(pipeline, "command", side_effect=fake_command):
            with self.assertRaisesRegex(pipeline.Blocked, "independent reviewer"):
                pipeline.resolve_candidate(env)

    def test_uat_rejects_foreign_digest_source_or_snapshot(self):
        for field, bad in (("digest", "latest"), ("source_sha", "main"),
                           ("source_repository", "foreign/accounts"), ("tag", "another-tag")):
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                self.resolved("uat", lambda m: m["images"][0].update({field: bad}))

    def chain(self, value, raw):
        previous = {}
        for phase in pipeline.phase_sequence(value):
            previous[phase] = pipeline.validate_receipt(value, phase, raw[phase], previous)
        return previous

    def test_both_environment_chains(self):
        for environment in ("uat", "prod"):
            with self.subTest(environment=environment):
                value = candidate(environment)
                result = self.chain(value, receipts(value))
                self.assertEqual(result["verification"]["schema_version"], value["target_schema_version"])

    def test_inputs_fail_closed(self):
        for field, bad in (("DEPLOY_ENV", ""), ("DEPLOY_ENV", "production"),
                           ("UPGRADE_MODE", "restore"), ("RELEASE_TAG", "main"),
                           ("RELEASE_TAG", "v2026.10.04-r3"), ("EXPECTED_SCHEMA_VERSION", "0"),
                           ("TARGET_SCHEMA_VERSION", "2026092801"), ("MIGRATION_SHA256", "wrong"),
                           ("CANDIDATE_RUN_ID", ""), ("GITHUB_REF", "refs/heads/feature/test")):
            with self.subTest(field=field, bad=bad):
                env = request()
                env[field] = bad
                with self.assertRaises(pipeline.Blocked):
                    pipeline.inputs(env)

    def test_prod_requires_release_ref(self):
        env = request("prod")
        env["GITHUB_REF"] = "refs/heads/main"
        with self.assertRaisesRegex(pipeline.Blocked, "PROD must dispatch"):
            pipeline.inputs(env)

    def test_prod_rehearsal_rejected_before_network(self):
        with patch.object(pipeline, "command", side_effect=AssertionError("network contacted")):
            with self.assertRaisesRegex(pipeline.Blocked, "UAT-only"):
                pipeline.resolve_candidate(request("prod", "rehearsal"))

    def test_uat_rehearsal_requires_real_candidate_and_complete_rollback_chain(self):
        value = self.resolved("uat", mode="rehearsal")
        self.assertEqual(value["evidence_kind"], "live_candidate")
        self.assertEqual(pipeline.phase_sequence(value), pipeline.REHEARSAL_PHASES)
        value = candidate(mode="rehearsal")
        result = self.chain(value, receipts(value))
        self.assertEqual(result["rollback"]["running_digests"], result["preflight"]["rollback_digests"])
        self.assertEqual(result["final_verification"]["running_digests"], pipeline.digests(value))

    def test_synthetic_receipts_cannot_authorize_live_execution(self):
        value = candidate()
        value["evidence_kind"] = "offline_rehearsal"
        with self.assertRaisesRegex(pipeline.Blocked, "rehearsal cannot authorize"):
            pipeline.registered_adapters(value)

    def test_uat_rollback_retains_schema_and_requires_old_digests(self):
        for field, bad in (("no_database_restore", False), ("schema_retained", False),
                           ("running_digests", {}), ("schema_version", 7), ("dirty", True)):
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                value = candidate(mode="rehearsal")
                raw = receipts(value)
                raw["rollback"][field] = bad
                self.chain(value, raw)

    def test_rollback_requires_full_business_revalidation(self):
        for field in ("original_password_login", "permissions_preserved", "subscription_entitlements_preserved",
                      "quota_preserved", "financial_ledger_preserved", "usage_ledger_preserved",
                      "no_real_payment_or_refund", "runtime_digest_verified"):
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                value = candidate(mode="rehearsal")
                raw = receipts(value)
                raw["rollback"].pop(field)
                self.chain(value, raw)

    def test_prod_requires_full_rehearsal_run_before_network(self):
        env = request("prod")
        env.pop("REHEARSAL_RUN_ID")
        with patch.object(pipeline, "command", side_effect=AssertionError("network contacted")):
            with self.assertRaisesRegex(pipeline.Blocked, "full UAT rehearsal"):
                pipeline.resolve_candidate(env)

    def test_prod_refuses_incomplete_tampered_and_failed_rehearsals(self):
        for mutate in (lambda p: p["receipts"].pop("rollback"),
                       lambda p: p["receipts"].pop("repromotion"),
                       lambda p: p["receipts"].pop("final_verification"),
                       lambda p: p["receipts"]["rollback"].update(original_password_login=False),
                       lambda p: p["candidate"].update(migration_sha256="f" * 64),
                       lambda p: p["candidate"].update(password="PRIVATE")):
            with self.assertRaises(pipeline.Blocked):
                self.resolved("prod", mutate_rehearsal=mutate)
        for field, bad in (("status", "in_progress"), ("conclusion", "failure"),
                           ("head_branch", "feature/test"), ("path", ".github/workflows/selfhost-orchestrator.yml")):
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                self.resolved("prod", mutate_rehearsal_run=lambda r: r.update({field: bad}))

    def test_same_digest_redeployment_is_not_an_upgrade_rehearsal(self):
        value = candidate(mode="rehearsal")
        raw = receipts(value)
        raw["preflight"]["rollback_digests"] = pipeline.digests(value)
        with self.assertRaisesRegex(pipeline.Blocked, "different application digest"):
            self.chain(value, raw)

    def test_same_digest_standalone_preflight_and_backup_remain_valid(self):
        for mode in ("preflight", "backup", "upgrade"):
            value = candidate(mode=mode)
            raw = receipts(value)
            raw["preflight"]["rollback_digests"] = pipeline.digests(value)
            self.assertEqual(pipeline.validate_receipt(value, "preflight", raw["preflight"], {})["status"], "passed")

    def test_rehearsal_rerun_is_rejected_before_network(self):
        env = request("uat", "rehearsal") | {"GITHUB_RUN_ATTEMPT": "2"}
        with patch.object(pipeline, "command", side_effect=AssertionError("network contacted")):
            with self.assertRaisesRegex(pipeline.Blocked, "rehearsal reruns"):
                pipeline.resolve_candidate(env)

    def test_qualification_requires_every_stage_and_same_candidate(self):
        value = candidate(mode="rehearsal")
        for missing in pipeline.REHEARSAL_PHASES:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                public = Path(directory)
                for phase, receipt in receipts(value).items():
                    if phase != missing:
                        pipeline.write_json(public / (phase + ".json"), receipt)
                with self.assertRaises(pipeline.Blocked):
                    pipeline.qualify_rehearsal(value, public)
                self.assertFalse((public / "uat-rehearsal-qualification.json").exists())
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory)
            for phase, receipt in receipts(value).items():
                pipeline.write_json(public / (phase + ".json"), receipt)
            self.assertEqual(pipeline.qualify_rehearsal(value, public)["status"], "passed")
            wrong = receipts(value)["rollback"] | {"candidate_sha256": "a" * 64}
            pipeline.write_json(public / "rollback.json", wrong)
            with self.assertRaises(pipeline.Blocked):
                pipeline.qualify_rehearsal(value, public)

    def test_failed_attempt_blocks_rerun_and_qualification(self):
        value = candidate(mode="rehearsal")
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory)
            with patch.object(pipeline, "registered_adapters", return_value={"preflight": Path("preflight.sh")}):
                with self.assertRaises(pipeline.Blocked):
                    pipeline.execute_phase(value, "preflight", public,
                                           runner=lambda *a, **k: subprocess.CompletedProcess(a, 1))
                self.assertEqual(pipeline.read_json(public / "attempt-failed.json")["status"], "stopped")
                with self.assertRaisesRegex(pipeline.Blocked, "failed attempt"):
                    pipeline.execute_phase(value, "preflight", public,
                                           runner=lambda *a, **k: self.fail("same attempt resumed"))
            with self.assertRaisesRegex(pipeline.Blocked, "failed attempt"):
                pipeline.qualify_rehearsal(value, public)

    def test_failed_timeout_invalid_receipt_and_missing_receipt_stop_attempt(self):
        value = candidate(mode="rehearsal")
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired("delegate", 1, stderr="PRIVATE")
        def invalid(args, **kwargs):
            Path(kwargs["env"]["UPGRADE_RECEIPT_FILE"]).write_text('{"status":"failed"}')
            return subprocess.CompletedProcess(args, 0)
        for runner in (timeout, invalid, lambda *a, **k: subprocess.CompletedProcess(a, 0)):
            with tempfile.TemporaryDirectory() as directory:
                public = Path(directory)
                with patch.object(pipeline, "registered_adapters", return_value={"preflight": Path("preflight.sh")}):
                    with self.assertRaises((pipeline.Blocked, subprocess.TimeoutExpired)):
                        pipeline.execute_phase(value, "preflight", public, runner=runner)
                marker = pipeline.read_json(public / "attempt-failed.json")
                self.assertNotIn("PRIVATE", json.dumps(marker))
                self.assertEqual(marker["restart_policy"], "investigate_then_full_rehearsal")

    def test_upgrade_cannot_execute_rehearsal_rollback(self):
        with self.assertRaisesRegex(pipeline.Blocked, "not allowed"):
            pipeline.execute_phase(candidate("prod"), "rollback", Path("/unused"))

    def test_missing_adapters_block_before_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(pipeline.Blocked, "not registered"):
                pipeline.execute_phase(candidate(), "preflight", Path(directory),
                                       runner=lambda *a, **k: self.fail("adapter was run"))

    def test_one_reviewed_delegate_serves_all_registered_phases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            delegate = root / ".github/scripts/environment-upgrade/delegate.sh"
            delegate.parent.mkdir(parents=True)
            delegate.write_text("#!/bin/sh\nexit 1\n")
            registry = {"schema": 2, "uat": {"phases": list(pipeline.REHEARSAL_PHASES),
                        "delegate": {"path": ".github/scripts/environment-upgrade/delegate.sh",
                                     "sha256": pipeline.hashlib.sha256(delegate.read_bytes()).hexdigest()}},
                        "prod": {}}
            with patch.object(pipeline, "ROOT", root):
                selected = pipeline.registered_adapters(candidate(mode="rehearsal"), registry)
                self.assertEqual(len(selected), len(pipeline.REHEARSAL_PHASES))
                self.assertEqual(set(selected.values()), {delegate})
                registry["uat"]["delegate"]["sha256"] = "a" * 64
                with self.assertRaisesRegex(pipeline.Blocked, "checksum"):
                    pipeline.registered_adapters(candidate(mode="rehearsal"), registry)

    def test_preflight_cannot_mutate(self):
        with self.assertRaisesRegex(pipeline.Blocked, "preflight cannot mutate"):
            pipeline.execute_phase(candidate(mode="preflight"), "backup", Path("/unused"))

    def test_each_failed_missing_or_skipped_stage_blocks(self):
        for phase in pipeline.PHASES:
            for status in ("failed", "skipped", "blocked", None):
                with self.subTest(phase=phase, status=status):
                    value = candidate()
                    raw = receipts(value)
                    raw[phase]["status"] = status
                    with self.assertRaises(pipeline.Blocked):
                        self.chain(value, raw)

    def test_each_required_check_is_falsifiable(self):
        for phase in pipeline.PHASES:
            for check, enabled in receipts(candidate())[phase].items():
                if type(enabled) is not bool or enabled is not True:
                    continue
                with self.subTest(phase=phase, check=check):
                    value = candidate()
                    raw = receipts(value)
                    raw[phase][check] = False
                    with self.assertRaises(pipeline.Blocked):
                        self.chain(value, raw)

    def test_cross_environment_run_candidate_replay_blocks(self):
        value = candidate()
        for field, replacement in (("environment", "prod"), ("candidate_sha256", "f" * 64)):
            raw = receipts(value)
            raw["backup"][field] = replacement
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                self.chain(value, raw)

    def test_empty_samples_block(self):
        for field in ("existing_users", "subscriptions"):
            for bad in (0, True, "1", None):
                with self.subTest(field=field, bad=bad):
                    value = candidate()
                    raw = receipts(value)
                    raw["preflight"][field] = bad
                    with self.assertRaises(pipeline.Blocked):
                        self.chain(value, raw)

    def test_production_restore_target_rejected(self):
        value = candidate("prod")
        raw = receipts(value)
        raw["backup"]["restore_database_identity"] = raw["backup"]["source_database_identity"]
        with self.assertRaisesRegex(pipeline.Blocked, "must be isolated"):
            self.chain(value, raw)

    def test_backup_must_use_environment_local_selfhost_and_preserve_fallback(self):
        for field, bad in (("backup_backend", "s3"), ("backup_environment", "prod"),
                           ("backup_host_identity", ""), ("fallback_runtime_preserved", False),
                           ("fallback_database_preserved", False), ("gitops_backup_host_verified", False)):
            with self.subTest(field=field), self.assertRaises(pipeline.Blocked):
                value = candidate()
                raw = receipts(value)
                raw["backup"][field] = bad
                self.chain(value, raw)

    def test_wrong_version_checksum_checkpoint_digest_and_rollback_block(self):
        for phase, field, bad in (
            ("preflight", "schema_version", 7), ("backup", "schema_version", 7),
            ("migration", "after_version", 7), ("migration", "migration_sha256", "f" * 64),
            ("migration", "checkpoint_id", "another_backup"), ("promotion", "running_digests", {}),
            ("promotion", "rollback_digests", {}), ("verification", "dirty", True),
            ("verification", "schema_version", 7), ("verification", "running_digests", {})):
            with self.subTest(phase=phase, field=field):
                value = candidate()
                raw = receipts(value)
                raw[phase][field] = bad
                with self.assertRaises(pipeline.Blocked):
                    self.chain(value, raw)

    def test_sensitive_unknown_receipt_fields_not_published(self):
        value = candidate()
        raw = receipts(value)
        for receipt in raw.values():
            receipt.update(password="PRIVATE", dsn="PRIVATE", email="PRIVATE", sql_dump="PRIVATE")
        self.assertNotIn("PRIVATE", json.dumps(self.chain(value, raw)))

    def test_complete_chain_executes_in_order_and_publishes_only_safe_receipts(self):
        value = candidate()
        raw = receipts(value)
        calls = []
        def runner(args, **kwargs):
            phase = Path(args[1]).stem
            calls.append(phase)
            Path(kwargs["env"]["UPGRADE_RECEIPT_FILE"]).write_text(json.dumps(raw[phase]))
            return subprocess.CompletedProcess(args, 0)
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory)
            pipeline.write_json(public / "candidate.json", value)
            adapters = {phase: Path(phase + ".sh") for phase in pipeline.PHASES}
            with patch.object(pipeline, "registered_adapters", return_value=adapters):
                for phase in pipeline.PHASES:
                    pipeline.execute_phase(value, phase, public, runner)
            self.assertEqual(calls, list(pipeline.PHASES))

    def test_missing_preceding_phase_prevents_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(pipeline, "registered_adapters", return_value={"migration": Path("migration.sh")}):
                with self.assertRaises(pipeline.Blocked):
                    pipeline.execute_phase(candidate(), "migration", Path(directory),
                                           runner=lambda *a, **k: self.fail("migration was run"))

    def test_failure_does_not_publish_success_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory)
            with patch.object(pipeline, "registered_adapters", return_value={"preflight": Path("preflight.sh")}):
                with self.assertRaises(pipeline.Blocked):
                    pipeline.execute_phase(candidate(), "preflight", public,
                                           runner=lambda *a, **k: subprocess.CompletedProcess(a, 1))
            self.assertFalse((public / "preflight.json").exists())

    def test_fixed_delegate_fails_closed_without_writing_receipt(self):
        delegate = ROOT / ".github/scripts/environment-upgrade/delegate.sh"
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            env = dict(os.environ, DEPLOY_ENV="uat", UPGRADE_PHASE="migration",
                       UPGRADE_OPERATION="migration",
                       UPGRADE_PLAYBOOKS_REPOSITORY="ai-workspace-infra/playbooks",
                       UPGRADE_PLAYBOOKS_REF="a" * 40,
                       UPGRADE_PLAYBOOKS_WORKFLOW=".github/workflows/selfhost-data-lifecycle.yml",
                       UPGRADE_RECEIPT_FILE=str(receipt))
            result = subprocess.run(["bash", str(delegate)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not registered", result.stderr)
            self.assertFalse(receipt.exists())

    def test_fixed_delegate_rejects_rollback_before_any_dispatch(self):
        delegate = ROOT / ".github/scripts/environment-upgrade/delegate.sh"
        env = dict(os.environ, DEPLOY_ENV="uat", UPGRADE_PHASE="rollback",
                   UPGRADE_OPERATION="rollback",
                   UPGRADE_PLAYBOOKS_REPOSITORY="ai-workspace-infra/playbooks",
                   UPGRADE_PLAYBOOKS_REF="a" * 40,
                   UPGRADE_PLAYBOOKS_WORKFLOW=".github/workflows/selfhost-data-lifecycle.yml")
        result = subprocess.run(["bash", str(delegate)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback rehearsal adapter is not registered", result.stderr)

    def test_requested_mode_verdict_never_accepts_skipped_or_failed_jobs(self):
        for mode, final in (("preflight", "preflight"), ("rehearsal", "upgrade"), ("upgrade", "upgrade")):
            result = {name: {"result": "success"} for name in ("candidate", "preflight", final)}
            self.assertTrue(pipeline.verdict(mode, result))
            for failure in ("skipped", "failure", "cancelled"):
                with self.subTest(mode=mode, failure=failure):
                    result[final]["result"] = failure
                    with self.assertRaises(pipeline.Blocked):
                        pipeline.verdict(mode, result)


if __name__ == "__main__":
    print("OFFLINE REHEARSAL ONLY: synthetic receipts, no database/cloud/payment changes.", flush=True)
    unittest.main(verbosity=2)
