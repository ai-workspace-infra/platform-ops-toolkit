"""Keep post-DNS host operations behind the reviewed Playbooks roles."""

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/selfhost-orchestrator.yml"


class PostDeployReadinessOwnerContractTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text())

    def test_web_saas_checks_call_pinned_playbooks_role_on_matrix_host(self):
        job = self.workflow["jobs"]["observe_web_saas_after_dns"]
        steps = {step.get("name"): step for step in job["steps"]}
        checkout = steps["Checkout playbooks"]
        readiness = steps["Verify Web SaaS host with Playbooks role"]
        self.assertEqual(checkout["with"]["ref"], "${{ needs.provision.outputs.playbooks_ref }}")
        self.assertEqual(readiness["working-directory"], "playbooks")
        self.assertIn("verify_web_saas_post_deploy.yml", readiness["run"])
        self.assertIn("--inventory ../cmdb/inventory.ini", readiness["run"])
        self.assertIn('--limit "${MATRIX_HOST}"', readiness["run"])
        self.assertIn("web_saas_canonical_probe_host=${WEB_SAAS_CANONICAL_PROBE_HOST}", readiness["run"])
        self.assertNotIn("platform-ops_observe-web-saas-containers.sh", readiness["run"])

    def test_agent_proxy_checks_call_pinned_playbooks_role_on_matrix_host(self):
        job = self.workflow["jobs"]["observe_agent_proxy_after_dns"]
        steps = {step.get("name"): step for step in job["steps"]}
        checkout = steps["Checkout playbooks"]
        readiness = steps["Verify Agent Proxy host with Playbooks role"]
        self.assertEqual(checkout["with"]["ref"], "${{ needs.provision.outputs.playbooks_ref }}")
        self.assertEqual(readiness["working-directory"], "playbooks")
        self.assertIn("verify_agent_proxy_post_dns.yml", readiness["run"])
        self.assertIn('--limit "${MATRIX_HOST}"', readiness["run"])
        self.assertNotIn("platform-ops_observe-agent-proxy.sh", readiness["run"])


if __name__ == "__main__":
    unittest.main()
