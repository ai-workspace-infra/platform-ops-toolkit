import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/open-platform-orchestrator.yml"


class OpenPlatformOrchestratorContractTests(unittest.TestCase):
    def test_all_reconciles_shared_states_in_order_before_services(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        jobs = document["jobs"]

        self.assertEqual(jobs["vault-iac"]["needs"], "contract")
        self.assertEqual(jobs["observability-iac"]["needs"], ["contract", "vault-iac"])
        self.assertEqual(jobs["iam-iac"]["needs"], ["contract", "observability-iac"])
        self.assertEqual(
            jobs["services"]["needs"],
            ["contract", "vault-iac", "observability-iac", "iam-iac"],
        )

        self.assertIn("needs.vault-iac.result == 'success'", jobs["observability-iac"]["if"])
        self.assertIn("needs.observability-iac.result == 'success'", jobs["iam-iac"]["if"])

    def test_shared_vault_dispatch_uses_shared_target_manifest(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        jobs = document["jobs"]
        steps = jobs["services"]["steps"]
        dispatch_step = next(
            step
            for step in steps
            if step.get("name") == "Dispatch and wait for shared service workflows"
        )
        script = dispatch_step["run"]

        self.assertIn(
            'service_manifest:"resources/svc.plus/shared/vault/server.yaml"',
            script,
        )
        self.assertIn(
            'provider_manifest:"resources/svc.plus/shared/gcp/open-platform-shared-vault.yaml"',
            script,
        )
        self.assertIn(
            "dispatch_and_wait zitadel-server.yml \"ZITADEL deploy\"",
            script,
        )
        self.assertIn(
            'provider_manifest:"resources/svc.plus/shared/gcp/open-platform-shared-iam.yaml"',
            script,
        )
        self.assertIn('--arg vault_addr "${VAULT_ADDR}"', script)
        self.assertLess(
            script.index('dispatch_and_wait zitadel-server.yml "ZITADEL deploy"'),
            script.index('dispatch_and_wait observability-server.yml'),
        )
        self.assertNotIn(
            'provider_manifest:"resources/xworktech.com/shared/gcp/vault-shared.yaml"',
            script,
        )


    def _dispatch_script(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = document["jobs"]["services"]["steps"]
        return next(
            step for step in steps if step.get("name") == "Dispatch and wait for shared service workflows"
        )["run"]

    def test_every_dispatch_payload_matches_its_target_workflow_inputs(self):
        # A dispatched input the child does not declare, an invalid choice, or
        # a manifest path the child rejects only fails after the preceding
        # service stages have already run. Assert the contract here instead.
        script = self._dispatch_script()
        targets = {
            "vault_payload": "vault-server.yml",
            "zitadel_payload": "zitadel-server.yml",
            "observability_payload": "observability-server.yml",
        }
        for variable, workflow in targets.items():
            with self.subTest(workflow=workflow):
                match = re.search(variable + r'="\$\(jq -n(.*?)\)"\n', script, re.S)
                self.assertIsNotNone(match, f"{variable} is not built with jq")
                body = re.search(r"'\{ref:\$ref,inputs:\{(.*)\}\}'", match.group(1), re.S).group(1)
                sent = re.findall(r"(?:^|,)([a-z_]+):", body)
                literals = dict(re.findall(r'([a-z_]+):"([^"]*)"', body))
                target = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8"))
                declared = (target.get("on") or target[True])["workflow_dispatch"]["inputs"]

                self.assertTrue(sent)
                for key in sent:
                    self.assertIn(key, declared, f"{workflow} does not declare input {key}")
                for key, value in literals.items():
                    spec = declared[key]
                    if spec.get("type") == "choice":
                        self.assertIn(value, spec["options"], f"{workflow} rejects {key}={value}")
                    if key.endswith("manifest"):
                        self.assertEqual(value, spec["default"], f"{workflow} {key} must be its reviewed declaration")

    def test_observability_dispatch_uses_shared_observability_manifest(self):
        script = self._dispatch_script()
        self.assertIn(
            'gcp_resource_manifest:"resources/svc.plus/shared/gcp/open-platform-shared-observability.yaml"',
            script,
        )
        self.assertFalse("resources.svc.plus" in script, "Observability manifest path contains resources.svc.plus")

if __name__ == "__main__":
    unittest.main()
