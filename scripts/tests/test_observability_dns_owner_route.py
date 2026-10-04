"""Exercise the real DNS executor and Ansible Role using only stubbed external I/O."""

import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/observability-server.yml").read_text())
JOB = WORKFLOW["jobs"]["dns_switch"]
STEPS = JOB["steps"]


def step_by_id(name):
    return next(step for step in STEPS if step.get("id") == name)


def import_file(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DnsOwnerContractTests(unittest.TestCase):
    def test_owner_checkouts_are_immutable_and_precede_calls(self):
        for repo, call_id in (("iac_modules", "dns_change"), ("playbooks", "service_acceptance")):
            checkout = next(step for step in STEPS if step.get("with", {}).get("path") == repo)
            self.assertRegex(checkout["with"]["ref"], r"^[0-9a-f]{40}$")
            self.assertLess(STEPS.index(checkout), STEPS.index(step_by_id(call_id)))
        self.assertIn("inputs.deploy_env == 'uat'", JOB["if"])

    def test_provider_and_host_calls_use_the_same_target_and_keep_credentials_scoped(self):
        change = step_by_id("dns_change")
        acceptance = step_by_id("service_acceptance")
        self.assertIn("iac_modules/scripts/pipeline/cloudflare-dns-record.py", change["run"])
        self.assertNotIn("SSH_PRIVATE_KEY_PATH", change["env"])
        self.assertIn("observability_operation=post_dns_cutover", acceptance["run"])
        self.assertEqual(acceptance["working-directory"], "playbooks")
        self.assertEqual(acceptance["if"], "inputs.dns_action == 'cutover'")
        self.assertNotIn("CLOUDFLARE_DNS_API_TOKEN", acceptance["env"])
        for vault in (step for step in STEPS if step.get("uses", "").startswith("hashicorp/vault-action@")):
            self.assertFalse(vault["with"]["exportEnv"])
        self.assertIn("needs.resolve_target.outputs.target_ip", JOB["env"]["TARGET_IP"])
        self.assertIn("DNS_RECORD_NAME", JOB["env"])
        self.assertIn("DNS_CHECKPOINT_PATH", JOB["env"])

    def test_failed_host_acceptance_requests_iaC_restore_without_masking_failure(self):
        acceptance = step_by_id("service_acceptance")
        recovery = next(step for step in STEPS if step.get("env", {}).get("DNS_ACTION") == "restore")
        self.assertNotIn("continue-on-error", acceptance)
        for condition in ("failure()", "inputs.dns_action == 'cutover'",
                          "steps.dns_change.outcome == 'success'",
                          "steps.service_acceptance.outcome == 'failure'"):
            self.assertIn(condition, recovery["if"])
        self.assertEqual(recovery["run"], step_by_id("dns_change")["run"])
        self.assertLess(STEPS.index(acceptance), STEPS.index(recovery))

    def test_job_budget_preserves_bounded_recovery_after_host_timeout(self):
        recovery = next(step for step in STEPS if step.get("env", {}).get("DNS_ACTION") == "restore")
        budgets = [step_by_id("dns_change")["timeout-minutes"],
                   step_by_id("service_acceptance")["timeout-minutes"],
                   recovery["timeout-minutes"]]
        self.assertTrue(all(budget > 0 for budget in budgets))
        self.assertGreaterEqual(JOB["timeout-minutes"], sum(budgets) + 5)


class NonMutatingCutoverRehearsalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        iac = Path(os.environ.get("IAC_DNS_TEST_ROOT", ROOT / "pipeline-contract/iac_modules"))
        playbooks = Path(os.environ.get("PLAYBOOKS_DNS_TEST_ROOT", ROOT / "pipeline-contract/playbooks"))
        cls.dns_fixture = import_file("dns_owner_fixture", iac / "scripts/pipeline/tests/test_cloudflare_dns_record.py")
        cls.host_fixture = import_file("host_owner_fixture", playbooks / "tests/test_observability_post_dns_cutover.py")
        cls.playbooks = playbooks

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.host = self.host_fixture.PostDnsCutoverTests()
        self.host.setUp()
        self.addCleanup(self.host.doCleanups)
        self.client = self.dns_fixture.FakeCloudflare()
        self.client.current["name"] = JOB["env"]["DNS_RECORD_NAME"]
        self.original = copy.deepcopy(self.client.current)
        self.env = {
            "DNS_ENVIRONMENT": "uat", "DNS_ZONE": JOB["env"]["DNS_ZONE"],
            "DNS_RECORD_NAME": JOB["env"]["DNS_RECORD_NAME"], "DNS_ACTION": "cutover",
            "SOURCE_IP": "203.0.113.1", "TARGET_IP": "203.0.113.2",
            "DNS_CHECKPOINT_PATH": str(Path(self.temporary.name) / "dns.json"),
        }

    def rehearsal(self, restart="true", **failures):
        dns = self.dns_fixture.MODULE
        dns.execute(dns.Config.from_env(self.env), self.client, lambda *_: True)
        acceptance = step_by_id("service_acceptance")
        env = dict(self.host.env, **self.env, RESTART_CADDY=restart, **failures)
        env["POST_DNS_HEALTH_PATH"] = acceptance["env"]["POST_DNS_HEALTH_PATH"]
        env["POST_DNS_SSH_USER"] = acceptance["env"]["POST_DNS_SSH_USER"]
        result = subprocess.run(["bash", "-c", acceptance["run"]], cwd=self.playbooks,
                                env=env, capture_output=True, text=True)
        if result.returncode:
            dns.execute(dns.Config.from_env(dict(self.env, DNS_ACTION="restore")),
                        self.client, lambda *_: True)
        return result

    def test_cutover_runs_role_acceptance_after_provider_write(self):
        result = self.rehearsal()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.client.current["content"], self.env["TARGET_IP"])
        self.assertEqual(len(self.client.updates), 1)
        self.assertTrue(self.host.log.read_text().splitlines()[0].startswith("ssh "))

    def test_failed_caddy_refresh_restores_original_record_and_remains_failed(self):
        result = self.rehearsal(TEST_SSH_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.client.current, self.original)
        self.assertNotIn("curl ", self.host.log.read_text())

    def test_failed_https_acceptance_restores_original_record_and_remains_failed(self):
        result = self.rehearsal(TEST_CURL_CODE="503")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.client.current, self.original)
        self.assertEqual(len(self.client.updates), 2)

    def test_shared_cutover_checks_https_without_restarting_caddy(self):
        result = self.rehearsal(restart="false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("ssh ", self.host.log.read_text())


if __name__ == "__main__":
    unittest.main()
