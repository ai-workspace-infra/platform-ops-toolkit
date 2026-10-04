"""Rehearse the actual Toolkit caller with the pinned Role, no external I/O."""

import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/observability-server.yml").read_text())
JOB = WORKFLOW["jobs"]["deploy_shared_target"]
STEPS = JOB["steps"]
CALL = next(step for step in STEPS if step.get("id") == "local_health")
CHECKOUT = next(step for step in STEPS if step.get("with", {}).get("path") == "observability-operations")


class LocalHealthCallerContractTests(unittest.TestCase):
    def test_pinned_owner_precedes_health_and_cleanup_and_uses_exact_inventory(self):
        self.assertEqual(CHECKOUT["with"]["repository"], "ai-workspace-infra/playbooks")
        self.assertRegex(CHECKOUT["with"]["ref"], r"^[a-f0-9]{40}$")
        self.assertFalse(CHECKOUT["with"]["persist-credentials"])
        self.assertEqual(CALL["env"]["OWNER_SHA"], CHECKOUT["with"]["ref"])
        self.assertEqual(CALL["working-directory"], CHECKOUT["with"]["path"])
        self.assertEqual(CALL["env"]["ACCESS_DIR"], "${{ steps.access.outputs.access_dir }}")
        self.assertEqual(CALL["env"]["NODE_NAME"], "${{ steps.target.outputs.node_name }}")
        self.assertIn('test "$(git rev-parse HEAD)" = "${OWNER_SHA}"', CALL["run"])
        self.assertIn('-i "${ACCESS_DIR}/inventory.ini"', CALL["run"])
        self.assertIn('observability_local_health_host=${NODE_NAME}', CALL["run"])
        self.assertIn('observability_operations_environment=uat', CALL["run"])
        self.assertIn('observability_operation=verify_local_grafana', CALL["run"])
        self.assertIn("inputs.deploy_env == 'uat'", JOB["if"])
        self.assertNotIn("continue-on-error", CALL)
        self.assertLess(STEPS.index(CHECKOUT), STEPS.index(CALL))
        cleanup = next(step for step in STEPS if step["name"].startswith("Revoke temporary"))
        self.assertLess(STEPS.index(CALL), STEPS.index(cleanup))
        self.assertIn("always()", cleanup["if"])

    def test_ci_rehearsal_uses_same_immutable_owner_version(self):
        ci = yaml.safe_load((ROOT / ".github/workflows/validate-release-pr.yml").read_text())
        steps = ci["jobs"]["workflow-gating"]["steps"]
        checkout = next(step for step in steps if step.get("with", {}).get("path") == "pipeline-contract/local-health-playbooks")
        self.assertEqual(checkout["with"]["ref"], CHECKOUT["with"]["ref"])
        self.assertIn("tests/test_observability_local_grafana.py", checkout["with"]["sparse-checkout"])
        self.assertTrue(any("test_observability_local_health_owner_route.py" in step.get("run", "") for step in steps))


class LocalHealthCallerRehearsalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.owner = Path(os.environ.get("PLAYBOOKS_LOCAL_HEALTH_TEST_ROOT", ROOT / "pipeline-contract/local-health-playbooks"))
        spec = importlib.util.spec_from_file_location("local_health_fixture", cls.owner / "tests/test_observability_local_grafana.py")
        cls.fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.fixture)

    def setUp(self):
        self.host = self.fixture.LocalGrafanaTests()
        self.host.setUp()
        self.addCleanup(self.host.doCleanups)
        self.directory = Path(self.host.temporary.name)
        self.summary = self.directory / "summary.md"
        (self.directory / "inventory.ini").write_text(
            "[observability_hosts]\nfixture-node ansible_connection=local ansible_host=127.0.0.1 "
            "ansible_become=false\n[controllers]\nlocalhost ansible_connection=local\n"
            "[all:vars]\nobservability_local_health_retries=1\n"
            "observability_local_health_delay=0\n"
            f"observability_local_grafana_port={self.host.server.server_port}\n"
        )

    def run_caller(self, **overrides):
        env = dict(os.environ, ACCESS_DIR=str(self.directory), NODE_NAME="fixture-node",
                   OWNER_SHA=CHECKOUT["with"]["ref"], GITHUB_SHA="fixture-toolkit-sha",
                   GITHUB_STEP_SUMMARY=str(self.summary), ANSIBLE_NOCOLOR="1")
        env.update(overrides)
        return subprocess.run(["bash", "-c", CALL["run"]], cwd=self.owner, env=env,
                              capture_output=True, text=True, timeout=60)

    def test_healthy_pinned_route_emits_identity_after_success(self):
        result = self.run_caller()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.host.calls, ["/api/health"])
        summary = self.summary.read_text()
        self.assertIn(CHECKOUT["with"]["ref"], summary)
        self.assertIn("fixture-toolkit-sha", summary)
        self.assertIn("fixture-node", summary)
        self.assertNotIn("never-print-this", result.stdout + result.stderr + summary)

    def test_unhealthy_service_fails_before_success_summary(self):
        self.host.body = b'{"database":"failed"}'
        result = self.run_caller()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.host.calls)
        self.assertFalse(self.summary.exists())

    def test_wrong_sha_or_target_fails_without_probing_or_summary(self):
        for overrides in ({"OWNER_SHA": "0" * 40}, {"NODE_NAME": "missing-node"}):
            with self.subTest(overrides=overrides):
                result = self.run_caller(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.host.calls, [])
                self.assertFalse(self.summary.exists())


if __name__ == "__main__":
    unittest.main()
