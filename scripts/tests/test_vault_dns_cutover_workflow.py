import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/vault-dns-cutover.yml"


class VaultDnsCutoverWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        cls.trigger = cls.document[True]["workflow_dispatch"]
        cls.inputs = cls.trigger["inputs"]
        cls.jobs = cls.document["jobs"]

    def test_manual_inputs_and_safe_default(self):
        self.assertEqual(self.inputs["dns_action"]["options"], ["verify", "switch", "rollback"])
        self.assertEqual(self.inputs["dns_action"]["default"], "verify")
        self.assertEqual(self.inputs["target_domain"]["default"], "vault.svc.plus")
        self.assertNotIn("CLOUDFLARE_API_TOKEN", self.inputs)
        self.assertEqual(len(self.inputs), 11)

    def test_matrix_contains_the_three_new_nodes_and_legacy_rollback(self):
        matrix = self.jobs["validate-targets"]["strategy"]["matrix"]["include"]
        self.assertEqual([item["node"] for item in matrix], [
            "vault-prod-0", "vault-prod-1", "vault-prod-2", "vault-legacy",
        ])
        self.assertEqual([item["role"] for item in matrix], ["leader", "standby", "standby", "legacy-standby"])

    def test_mutation_requires_all_matrix_checks_and_explicit_confirmation(self):
        cutover = self.jobs["cutover"]
        self.assertEqual(cutover["needs"], "validate-targets")
        self.assertIn("inputs.dns_action == 'switch'", cutover["if"])
        self.assertIn("inputs.dns_action == 'rollback'", cutover["if"])
        source = "\n".join(step.get("run", "") for step in cutover["steps"])
        self.assertIn("SWITCH-VAULT-DNS", source)
        self.assertIn("ROLLBACK-VAULT-DNS", source)
        self.assertIn("proxied:false", source)
        self.assertIn("expected exactly one active Cloudflare zone", source)

    def test_post_cutover_verification_checks_public_resolvers(self):
        verify = self.jobs["verify-dns"]
        self.assertEqual(verify["strategy"]["matrix"]["resolver"], ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        self.assertIn("dig +short", verify["steps"][0]["run"])
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('[[ "${DOMAIN}" == vault.svc.plus ]]', source)


if __name__ == "__main__":
    unittest.main()
