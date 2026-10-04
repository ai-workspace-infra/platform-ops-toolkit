#!/usr/bin/env python3
"""Falsify business promotion gates independently of a green deployment."""
import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("promotion", ROOT / ".github/scripts/snapshots/verify-promotion-manifest.py")
promotion = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(promotion)
TAG = "daily-build-2026.10.04-r1"


class BusinessPromotionGateTests(unittest.TestCase):
    def setUp(self):
        base = {"schema": 1, "environment": "uat", "snapshot_tag": TAG, "uat_run_id": "4242",
                "images": [{"service": service, "image": f"asia-east1-docker.pkg.dev/open-platform-uat/serverless/{service}",
                            "tag": TAG, "digest": "sha256:" + "a" * 64,
                            "source_repository": f"ai-workspace-services/{service}", "source_sha": "c" * 40}
                           for service in promotion.REQUIRED_SERVICES]}
        self.manifest = json.loads(subprocess.check_output(
            ["jq", "-f", str(ROOT / ".github/scripts/tests/fixtures/uat-upgrade-acceptance.jq")],
            input=json.dumps(base).encode()))

    def refused(self, manifest, text):
        with self.assertRaisesRegex(promotion.Refused, text):
            promotion.normalize(manifest, TAG, None)

    def test_complete_evidence_is_preserved(self):
        normalized = promotion.normalize(self.manifest, TAG, None)
        self.assertEqual(normalized["upgrade_acceptance"], self.manifest["upgrade_acceptance"])

    def test_green_deployment_without_business_evidence_is_blocked(self):
        del self.manifest["upgrade_acceptance"]
        self.refused(self.manifest, "missing UAT upgrade/login/subscription")

    def test_each_unexecuted_or_failed_gate_is_blocked(self):
        for name in promotion.GATE_CHECKS:
            for status in ("blocked", "failed", "skipped", None):
                with self.subTest(gate=name, status=status):
                    record = copy.deepcopy(self.manifest)
                    record["upgrade_acceptance"]["gates"][name]["status"] = status
                    self.refused(record, f"{name} was not demonstrated")

    def test_sql_only_login_and_each_missing_check_are_blocked(self):
        for name, checks in promotion.GATE_CHECKS.items():
            for check in checks:
                with self.subTest(check=check):
                    record = copy.deepcopy(self.manifest)
                    record["upgrade_acceptance"]["gates"][name][check] = False
                    self.refused(record, check)

    def test_empty_missing_or_boolean_sample_count_is_blocked(self):
        for field in ("existing_users", "subscriptions"):
            for count in (0, -1, None, True, "1"):
                with self.subTest(field=field, count=count):
                    record = copy.deepcopy(self.manifest)
                    record["upgrade_acceptance"]["baseline"][field] = count
                    self.refused(record, f"baseline {field} must be non-empty")

    def test_absent_or_incomplete_migration_is_blocked(self):
        for change, reason in (({"expected_version": None}, "explicit target"),
                               ({"before_version": None}, "recognized migration baseline"),
                               ({"before_dirty": True}, "recognized migration baseline"),
                               ({"actual_version": 2026090802}, "exact target"),
                               ({"actual_version": 2026092802}, "exact target"),
                               ({"dirty": True}, "dirty must be false"),
                               ({"dirty": "false"}, "dirty must be false")):
            with self.subTest(change=change):
                record = copy.deepcopy(self.manifest)
                record["upgrade_acceptance"]["migration"].update(change)
                self.refused(record, reason)

    def test_different_tag_or_digest_evidence_is_blocked(self):
        self.manifest["upgrade_acceptance"]["snapshot_tag"] = "daily-build-2026.10.03-r1"
        self.refused(self.manifest, "different target tag")
        self.manifest["upgrade_acceptance"]["snapshot_tag"] = TAG
        self.manifest["upgrade_acceptance"]["images"][0]["digest"] = "sha256:" + "b" * 64
        self.refused(self.manifest, "promoted image digests")

    def test_same_version_redeploy_is_not_upgrade_evidence(self):
        self.manifest["upgrade_acceptance"]["baseline"]["snapshot_tag"] = TAG
        self.refused(self.manifest, "same-tag redeployment")

    def test_missing_reviewable_evidence_is_blocked(self):
        for urls in ([], ["https://example.test/pass"], [None]):
            record = copy.deepcopy(self.manifest)
            record["upgrade_acceptance"]["gates"]["original_user_login"]["evidence_urls"] = urls
            self.refused(record, "reviewable UAT run evidence")

    def test_unrecognized_fields_cannot_publish_secrets(self):
        self.manifest["upgrade_acceptance"]["password"] = "must-not-publish"
        result = promotion.normalize(self.manifest, TAG, None)
        self.assertNotIn("must-not-publish", json.dumps(result))

    def test_untrusted_branch_or_event_is_blocked(self):
        run = {"id": 4242, "path": promotion.HYBRID_WORKFLOW_PATH, "status": "completed",
               "conclusion": "success", "head_branch": "main", "event": "workflow_dispatch"}
        promotion.check_uat_run(run, "4242")
        for field, value in (("head_branch", "feature"), ("event", "pull_request")):
            with self.assertRaisesRegex(promotion.Refused, "protected main"):
                promotion.check_uat_run({**run, field: value}, "4242")

    def test_deployment_summary_cannot_hide_skipped_business_acceptance(self):
        script = ROOT / ".github/scripts/platform-ops/observe/platform-ops_deployment-summary.sh"
        for result in ("skipped", "failure", "", "success"):
            with self.subTest(result=result):
                command = subprocess.run(["bash", str(script)], capture_output=True, text=True, env={
                    **os.environ, "DEPLOYMENT_ENV": "uat", "RUN_APPLICATION_DEPLOY": "true",
                    "TARGET_DOMAINS": "web-saas", "WEB_SAAS_ACCEPTANCE_RESULT": result,
                    "GITHUB_STEP_SUMMARY": "",
                })
                self.assertEqual(command.returncode, 0 if result == "success" else 1)
        # A read-only plan must not demand a deployment acceptance.
        command = subprocess.run(["bash", str(script)], capture_output=True, env={
            **os.environ, "DEPLOYMENT_ENV": "uat", "RUN_APPLICATION_DEPLOY": "false",
            "TARGET_DOMAINS": "web-saas", "GITHUB_STEP_SUMMARY": "",
        })
        self.assertEqual(command.returncode, 0)

    def test_schema_target_is_resolved_from_the_checked_out_tag(self):
        resolver = ROOT / ".github/scripts/platform-ops/observe/resolve-accounts-upgrade-target.py"
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            migration_dir = source / "sql/migrations"
            migration_dir.mkdir(parents=True)
            for name in ("2026090802_old.up.sql", "2026092801_target.up.sql"):
                (migration_dir / name).write_text("SELECT 1;\n")
            def git(*args):
                return subprocess.check_output(["git", "-C", temporary, *args], stderr=subprocess.DEVNULL)
            git("init", "-q")
            git("add", "sql")
            git("-c", "user.name=Contract Test", "-c", "user.email=contract@example.test",
                "-c", "commit.gpgsign=false", "commit", "-qm", "migration fixture")
            git("tag", TAG)
            def resolve(tag):
                return subprocess.run(["python3", str(resolver), "--source", temporary, "--tag", tag],
                                      capture_output=True, text=True)
            output = resolve(TAG)
            self.assertEqual(output.returncode, 0, output.stderr)
            self.assertIn("EXPECTED_ACCOUNTS_SCHEMA_VERSION=2026092801", output.stdout)
            self.assertNotEqual(resolve("main").returncode, 0)
            git("-c", "user.name=Contract Test", "-c", "user.email=contract@example.test",
                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "different checkout")
            self.assertNotEqual(resolve(TAG).returncode, 0)


if __name__ == "__main__":
    unittest.main()
