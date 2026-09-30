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


if __name__ == "__main__":
    unittest.main()
