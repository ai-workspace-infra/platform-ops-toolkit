#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "config" / "iac_provider_registry.json"
RESOLVER = ROOT / "scripts" / "iac" / "resolve_iac_contract.py"
WRITER = ROOT / "scripts" / "iac" / "write_external_inventory.py"


class IacStateContractTest(unittest.TestCase):
    def resolve(self, provider):
        output = subprocess.check_output(
            [sys.executable, str(RESOLVER), "--environment", "uat", "--project", "svc.plus", "--provider", provider, "--account", "primary", "--workspace", "web"],
            text=True,
        )
        return json.loads(output)

    def test_registry_covers_all_supported_provisioners(self):
        registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
        self.assertEqual(
            set(registry),
            {"aws-cloud", "gcp-cloud", "azure-cloud", "vultr-vps", "akamai-cloud", "ucloud", "ulighthost"},
        )
        for provider, contract in registry.items():
            resolved = self.resolve(provider)
            self.assertEqual(resolved["provisioner"], contract["provisioner"])
            if contract["provisioner"] == "terraform":
                self.assertEqual(resolved["terraform_tree"], contract["terraform_tree"])
                self.assertRegex(
                    resolved["state_key"],
                    r"^terraform/uat/svc\.plus/[^/]+/primary/web/terraform\.tfstate$",
                )
            else:
                self.assertIsNone(resolved["state_key"])
                self.assertIsNone(resolved["terraform_tree"])

    def test_terraform_state_key_has_all_five_boundaries(self):
        contract = self.resolve("akamai-cloud")
        self.assertEqual(contract["provisioner"], "terraform")
        self.assertEqual(
            contract["state_key"],
            "terraform/uat/svc.plus/akamai-cloud/primary/web/terraform.tfstate",
        )

    def test_existing_provider_is_not_a_terraform_adapter(self):
        contract = self.resolve("ulighthost")
        self.assertEqual(contract["provisioner"], "existing")
        self.assertEqual(contract["terraform_tree"], None)
        self.assertIsNone(contract["state_key"])

    def test_ucloud_uses_standard_terraform_contract(self):
        contract = self.resolve("ucloud")
        self.assertEqual(contract["provisioner"], "terraform")
        self.assertEqual(contract["terraform_tree"], "ucloud")
        self.assertEqual(
            contract["state_key"],
            "terraform/uat/svc.plus/ucloud/primary/web/terraform.tfstate",
        )

    def test_external_inventory_requires_existing_contract_and_strips_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            manifest = temp / "ulighthost.yaml"
            manifest.write_text(
                "global:\n  management_mode: existing\n  provisioner: ansible\n  lifecycle: external\nhosts:\n  - name: edge-a\n    ip: 203.0.113.4\n    api_token: must-not-be-recorded\n",
                encoding="utf-8",
            )
            inventory, run = temp / "inventory.json", temp / "run.json"
            subprocess.run(
                [sys.executable, str(WRITER), "--manifest", str(manifest), "--provider", "ulighthost", "--environment", "uat", "--project", "svc.plus", "--account", "primary", "--workspace", "edge", "--inventory-output", str(inventory), "--run-output", str(run)],
                check=True,
            )
            record = json.loads(inventory.read_text(encoding="utf-8"))
            self.assertEqual(record["resources"][0]["name"], "edge-a")
            self.assertNotIn("api_token", record["resources"][0])

    def test_workflow_adapters_keep_provider_credentials_and_state_separate(self):
        akamai = (ROOT / ".github" / "workflows" / "akamai-cloud-iac.yml").read_text(encoding="utf-8")
        external = (ROOT / ".github" / "workflows" / "external-inventory-state.yml").read_text(encoding="utf-8")
        ucloud = (ROOT / ".github" / "workflows" / "ucloud-iac.yml").read_text(encoding="utf-8")
        self.assertIn("TF_VAR_linode_token", akamai)
        self.assertIn("CICD/${{ inputs.vault_env_path }}/akamai-cloud/${{ inputs.account }}", akamai)
        self.assertNotIn("account_alias", akamai)
        self.assertIn("CICD/${{ inputs.vault_env_path }}/iac_state", akamai)
        self.assertIn("resolve_iac_contract.py", akamai)
        self.assertIn("steps.contract.outputs.state_key", akamai)
        self.assertIn("use_lockfile = true", akamai)
        self.assertNotIn('"endpoint = \\"${TF_STATE_ENDPOINT}\\""', akamai)
        self.assertIn("account must be a concrete account name or ID", akamai)
        self.assertIn("LINODE_TOKEN", (ROOT / "scripts" / "vault" / "bootstrap_akamai_cloud_kv.sh").read_text(encoding="utf-8"))
        self.assertIn("AKAMAI_ACCOUNT_UAT", (ROOT / "scripts" / "vault" / "bootstrap_akamai_oidc_roles.sh").read_text(encoding="utf-8"))
        self.assertNotIn("hashicorp/setup-terraform", external)
        self.assertNotIn("terraform -chdir", external)
        self.assertIn("options: [ulighthost]", external)
        self.assertIn("TF_VAR_ucloud_private_key", ucloud)
        self.assertIn("kv/data/CICD/${{ inputs.vault_env_path }}/ucloud/${{ inputs.account }}", ucloud)
        self.assertIn("terraform -chdir", ucloud)


if __name__ == "__main__":
    unittest.main()
