import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/vault-shared-gcp-iac.yml"


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


if __name__ == "__main__":
    unittest.main()
