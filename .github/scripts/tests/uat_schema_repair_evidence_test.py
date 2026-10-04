#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("repair", ROOT / ".github/scripts/serverless/uat_schema_repair_evidence.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def baseline(self):
        return {"rows": {"users": {"count": 23, "hmac": "private"},
                         "identities": {"count": 5, "hmac": "private"},
                         "subscriptions": {"count": 0, "hmac": "private"}},
                "migration": {"version": 2026092703, "dirty": False}}

    def after(self):
        result = self.baseline()
        result["migration"]["version"] = 2026092801
        result["rows"].update({n: {"count": 0, "hmac": "private"} for n in repair.FINANCE})
        return result

    def test_exact_clean_version_and_retention(self):
        repair.compare(self.baseline(), self.after())
        for version, dirty in ((2026092703, False), (2026092802, False), (2026092801, True)):
            after = self.after()
            after["migration"] = {"version": version, "dirty": dirty}
            with self.assertRaises(repair.Blocked):
                repair.compare(self.baseline(), after)

    def test_changes_and_deletions_block(self):
        for table in ("users", "identities", "subscriptions"):
            after = self.after()
            after["rows"][table]["hmac"] = "changed"
            with self.assertRaises(repair.Blocked):
                repair.compare(self.baseline(), after)
            del after["rows"][table]
            with self.assertRaises(repair.Blocked):
                repair.compare(self.baseline(), after)

    def test_no_financial_data_migration(self):
        after = self.after()
        after["rows"]["finance_payments"]["count"] = 1
        with self.assertRaises(repair.Blocked):
            repair.compare(self.baseline(), after)
        after = self.after()
        after["rows"]["unexpected"] = {"count": 0}
        with self.assertRaises(repair.Blocked):
            repair.compare(self.baseline(), after)

    def test_uat_connection_only_without_printing_values(self):
        raw = "postgres://postgres.abcdefghijklmnopqrst:fixture-private@aws-0-test.pooler.supabase.com:5432/postgres"
        with patch.dict(os.environ, {"PROJECT_REF": "abcdefghijklmnopqrst"}):
            self.assertEqual(repair.connection(raw)["PGSSLMODE"], "require")
            for bad in (raw.replace(":5432", ":6543"), raw + "?sslmode=disable", raw.replace(".pooler.supabase.com", ".example.invalid")):
                with self.assertRaises(repair.Blocked) as error:
                    repair.connection(bad)
                self.assertNotIn("fixture-private", str(error.exception))

    def test_report_never_passes_business_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            state, report = Path(directory) / "private", Path(directory) / "report"
            state.write_text(json.dumps({"key": "ab" * 32, "observation": self.baseline(), "identity": {"digest": "expected"}}))
            with patch.dict(os.environ, {"VAULT_ENV_PATH": "uat", "OFFICIAL_MIGRATOR_REPEAT_VERIFIED": "true"}), patch("sys.argv", ["probe", "after", "--state", str(state), "--report", str(report)]), patch.object(repair, "observe_serving", return_value={"digest": "expected"}), patch.object(repair, "capture", return_value=self.after()), patch.object(repair, "verify_finance"), patch("builtins.print"):
                repair.main()
            value = json.loads(report.read_text())
            self.assertFalse(value["eligible_for_prod"])
            self.assertEqual(value["subscriptions"], 0)
            self.assertNotIn("upgrade_acceptance", value)
            self.assertNotIn("hmac", report.read_text())
            self.assertNotIn("private", report.read_text())

    def serving_fixture(self):
        raw = "postgres://postgres.abcdefghijklmnopqrst:fixture-private@aws-0-test.pooler.supabase.com:5432/postgres"
        image = "asia-east1-docker.pkg.dev/open-platform-uat/serverless/accounts"
        service = {"status": {"latestReadyRevisionName": "uat-accounts-00001-abc",
            "latestCreatedRevisionName": "uat-accounts-00001-abc", "url": "https://uat-accounts-example.run.app",
            "traffic": [{"revisionName": "uat-accounts-00001-abc", "percent": 100}]}}
        revision = {"metadata": {"name": "uat-accounts-00001-abc"},
            "spec": {"containers": [{"image": image + ":" + repair.TAG,
                "env": [{"name": "SUPABASE_CONNECT_URI", "value": raw}]}]},
            "status": {"imageDigest": image + "@" + repair.DIGEST,
                "conditions": [{"type": "Ready", "status": "True"}]}}
        return raw, service, revision

    def test_serving_digest_database_and_health(self):
        raw, service, revision = self.serving_fixture()
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"status":"ok"}'
        with patch.dict(os.environ, {"PROJECT_REF": "abcdefghijklmnopqrst", "GCP_PROJECT_ID": "open-platform-uat", "GCP_REGION": "asia-east1"}), patch.object(repair, "urlopen", return_value=response):
            identity = repair.serving_identity(service, revision, repair.connection(raw))
            self.assertTrue(identity["database_identity_matches"])
            self.assertEqual(identity["snapshot_tag"], repair.TAG)
            self.assertNotIn("fixture-private", json.dumps(identity))

    def test_serving_mismatch_or_split_traffic_blocks(self):
        with patch.dict(os.environ, {"PROJECT_REF": "abcdefghijklmnopqrst", "GCP_PROJECT_ID": "open-platform-uat", "GCP_REGION": "asia-east1"}):
            for kind in ("digest", "database", "traffic", "not_ready"):
                raw, service, revision = self.serving_fixture()
                if kind == "digest":
                    revision["status"]["imageDigest"] = "wrong"
                elif kind == "database":
                    revision["spec"]["containers"][0]["env"][0]["value"] = raw.replace("fixture-private", "other-private")
                elif kind == "traffic":
                    service["status"]["traffic"][0]["percent"] = 50
                else:
                    revision["status"]["conditions"][0]["status"] = "False"
                with self.assertRaises(repair.Blocked):
                    repair.serving_identity(service, revision, repair.connection(raw))

    def test_source_exact_checksum_exception(self):
        script = (ROOT / ".github/scripts/serverless/apply_accounts_incremental_schema.sh").read_text()
        self.assertIn('"${target}" == 2026092801 && "${actual_sha}" == "${reviewed_finance_sha}"', script)
        self.assertEqual(script.count("go run ./cmd/migratectl migrate"), 2)
        self.assertNotIn("LIMIT 1", script)

    def test_workflow_repair_has_no_application_dispatch(self):
        import yaml
        workflow = yaml.safe_load((ROOT / ".github/workflows/serverless-orchestrator.yml").read_text())
        jobs = workflow["jobs"]
        self.assertIn("repair-schema", jobs["supabase"]["if"])
        self.assertIn("repair-schema", jobs["uat_accounts_schema_migration"]["if"])
        for job in ("cloud_run", "cloudflare_ssr", "frontend_router", "edge_gateway", "static_pages", "serverless_domains", "trigger_data_migration", "stripe_catalog"):
            self.assertNotIn("repair-schema", jobs[job]["if"])
        steps = jobs["uat_accounts_schema_migration"]["steps"]
        names = [s["name"] for s in steps]
        self.assertLess(names.index("Verify serving identity and capture private repair baseline"), names.index("Apply reviewed UAT Accounts schema migration"))
        artifact = next(s for s in steps if s["name"] == "Upload aggregate schema repair evidence only")
        self.assertEqual(artifact["with"]["path"], "${{ runner.temp }}/uat-schema-repair-report.json")
        metadata = next(j for j in jobs.values() if j.get("name") == "Record release identity for Operations Console")
        self.assertIn("supabase", metadata["needs"])
        self.assertIn("uat_accounts_schema_migration", metadata["needs"])


if __name__ == "__main__":
    unittest.main()
