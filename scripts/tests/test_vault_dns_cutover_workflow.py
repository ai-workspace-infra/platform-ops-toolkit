import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/vault-server.yml"


class VaultDnsCutoverWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        cls.trigger = cls.document[True]["workflow_dispatch"]
        cls.inputs = cls.trigger["inputs"]
        cls.jobs = cls.document["jobs"]

    def test_manual_inputs_and_safe_default(self):
        self.assertEqual(self.inputs["dns_action"]["options"], ["none", "verify", "switch", "rollback"])
        self.assertEqual(self.inputs["dns_action"]["default"], "none")
        self.assertNotIn("CLOUDFLARE_API_TOKEN", self.inputs)
        self.assertEqual(len(self.inputs), 10)
        self.assertNotIn("if", self.jobs["declaration"])
        self.assertIn("inputs.dns_action == 'none'", self.jobs["gcp-shared"]["if"])
        self.assertIn("len(names) not in (1, 3)", "\n".join(step.get("run", "") for step in self.jobs["dns-discovery"]["steps"]))

    def test_dns_runs_after_the_existing_vault_pipeline(self):
        discovery = self.jobs["dns-discovery"]
        self.assertEqual(
            discovery["needs"],
            ["declaration", "gcp-shared", "node-stage", "cleanup-node-access"],
        )
        self.assertIn("always()", discovery["if"])
        self.assertIn("needs.declaration.result == 'success'", discovery["if"])
        self.assertIn("needs.cleanup-node-access.result == 'skipped'", discovery["if"])
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("GCP_TARGETS", source)
        self.assertIn("mapfile -t targets", source)

    def test_matrix_uses_reviewed_manifest_and_live_gcp_addresses(self):
        discovery = self.jobs["dns-discovery"]
        source = "\n".join(step.get("run", "") for step in discovery["steps"])
        self.assertIn("service['storage']['leader']", source)
        self.assertIn("provider['resources']['vault_nodes']", source)
        self.assertIn("open-platform-shared-510113", source)
        self.assertIn("gcloud compute instances list", source)
        self.assertIn("'vault-legacy'", source)
        matrix = self.jobs["dns-validate-targets"]["strategy"]["matrix"]
        self.assertEqual(matrix["include"], "${{ fromJSON(needs.dns-discovery.outputs.matrix) }}")
        self.assertFalse(self.jobs["dns-validate-targets"]["strategy"]["fail-fast"])

    def test_mutation_requires_all_matrix_checks_and_explicit_confirmation(self):
        cutover = self.jobs["dns-cutover"]
        self.assertIn("dns-validate-targets", cutover["needs"])
        self.assertIn("needs.dns-validate-targets.result == 'success'", cutover["if"])
        self.assertIn("inputs.dns_action == 'switch'", cutover["if"])
        self.assertIn("inputs.dns_action == 'rollback'", cutover["if"])
        source = "\n".join(step.get("run", "") for step in cutover["steps"])
        self.assertIn("SWITCH-VAULT-DNS", source)
        self.assertIn("ROLLBACK-VAULT-DNS", source)
        self.assertIn("proxied:false", source)
        self.assertIn("expected exactly one active Cloudflare zone", source)
        self.assertLess(source.index('for target in "${targets[@]}"'), source.index('for record_id in "${stale_ids[@]}"'))

    def test_post_cutover_verification_checks_public_resolvers(self):
        verify = self.jobs["dns-verify"]
        self.assertEqual(verify["strategy"]["matrix"]["resolver"], ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
        self.assertIn("dig +short", verify["steps"][0]["run"])
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('[[ "${DOMAIN}" == vault.svc.plus ]]', source)


if __name__ == "__main__":
    unittest.main()
