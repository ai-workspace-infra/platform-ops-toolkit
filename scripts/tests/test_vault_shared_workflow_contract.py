import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/vault-server.yml"


class VaultSharedWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.source)

    def test_bootstrap_is_ephemeral_and_has_independent_cleanup(self):
        job = self.workflow["jobs"]["configure-services"]
        self.assertEqual(job["runs-on"], "ubuntu-latest")
        self.assertEqual(self.workflow[True]["workflow_dispatch"]["inputs"]["connection_mode"]["options"], ["bootstrap-public"])
        self.assertNotIn("runner.temp", str(job["env"]))
        names = {step["name"]: step for step in job["steps"]}
        self.assertIn("GITHUB_ENV", names["Set runner temporary paths"]["run"])
        self.assertIn("ansible.posix:==2.1.0", names["Prepare isolated manifest parser"]["run"])
        create = names["Temporarily open SSH for bootstrap job"]
        self.assertIn("--source-ranges=0.0.0.0/0", create["run"])
        self.assertIn("--target-tags=vault", create["run"])
        self.assertIn("connection_mode == 'bootstrap-public'", create["if"])
        self.assertIn("gcloud compute firewall-rules delete", names["Delete temporary public SSH rule"]["run"])
        fallback = self.workflow["jobs"]["cleanup-bootstrap-ssh"]
        self.assertIn("always()", fallback["if"])
        self.assertIn("gcloud compute firewall-rules delete", fallback["steps"][-1]["run"])

    def test_short_lived_wif_oslogin_and_pinned_host_keys(self):
        steps = self.workflow["jobs"]["configure-services"]["steps"]
        names = {step["name"]: step for step in steps}
        self.assertEqual(names["Read GCP runtime identity with stage-scoped Vault JWT role"]["with"]["method"], "jwt")
        self.assertIn("--ttl=65m", names["Prepare one-run OS Login SSH identity"]["run"])
        self.assertIn("prepare_known_hosts.py", names["Verify live SSH host keys against GitOps pins"]["run"])
        self.assertIn("StrictHostKeyChecking=yes", names["Apply selected Vault service playbook stage"]["env"]["ANSIBLE_SSH_COMMON_ARGS"])
        self.assertIn("gcloud compute os-login ssh-keys remove", names["Revoke temporary OS Login key and remove local key material"]["run"])

    def test_renamed_workflow_and_node_preflight(self):
        self.assertFalse((ROOT / ".github/workflows/vault-shared-gcp-iac.yml").exists())
        inputs = self.workflow[True]["workflow_dispatch"]["inputs"]
        self.assertIn("node-preflight", inputs["service_stage"]["options"])
        steps = {step["name"]: step for step in self.workflow["jobs"]["configure-services"]["steps"]}
        self.assertIn("ansible.builtin.ping", steps["Verify SSH access to all declared nodes"]["run"])
        self.assertIn("StrictHostKeyChecking=yes", steps["Verify SSH access to all declared nodes"]["env"]["ANSIBLE_SSH_COMMON_ARGS"])
        for role in ("node-oidc-open-platform-prod", "monitoring", "xconnect"):
            path = ROOT / "scripts/vault/roles" / f"github-actions-platform-ops-toolkit-shared-vault-{role}.json"
            self.assertIn(".github/workflows/vault-server.yml@refs/heads/main", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
