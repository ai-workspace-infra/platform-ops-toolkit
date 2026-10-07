#!/usr/bin/env python3
"""Regression checks for the non-IaC inventory and TLS owner handoff."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
OWNER_SHA = "feda3ef8bbf215b1f3fadb2fb801571f55090d2d"


class NonIaCOwnerHandoffContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = (ROOT / ".github/workflows/selfhost-orchestrator.yml").read_text()

    def test_inventory_adapter_is_pinned_to_the_playbooks_owner(self) -> None:
        owner = (
            "uses: ai-workspace-infra/playbooks/.github/actions/"
            f"non-iac-agent-proxy-inventory@{OWNER_SHA}"
        )
        self.assertEqual(self.workflow.count(owner), 1)
        self.assertNotIn(
            "platform-ops_deploy_render-non-iac-agent-proxy-inventory.py",
            self.workflow,
        )
        inventory = self.workflow.index("- name: Render non-IaC Agent Proxy inventory")
        preserve = self.workflow.index("- name: Preserve deploy-key access on non-IaC node")
        observe = self.workflow.index("- name: Deploy Observability Agent for non-IaC Agent Proxy")
        self.assertLess(inventory, preserve)
        self.assertLess(preserve, observe)
        segment = self.workflow[inventory:observe]
        self.assertIn("prepare_non_iac_ssh_access.yml", segment)
        self.assertIn("steps.inventory.outputs.inventory", segment)
        self.assertIn("steps.inventory.outputs.deploy_key_file", segment)
        self.assertIn("PreferredAuthentications=publickey,password", segment)

    def test_toolkit_keeps_the_vault_authorization_and_exact_reads(self) -> None:
        read = "- name: Read domain TLS record through the authorized Vault session"
        self.assertEqual(self.workflow.count(read), 2)
        self.assertEqual(self.workflow.count('test -n "${VAULT_TOKEN:-}"'), 3)
        # One exact read is for the external node record and two are for the
        # domain certificate. Response files cross the owner boundary.
        self.assertEqual(self.workflow.count('-H "X-Vault-Token: ${VAULT_TOKEN}"'), 3)
        self.assertEqual(self.workflow.count("200|404) ;;"), 2)
        self.assertEqual(
            self.workflow.count(
                "vault_response_file: ${{ steps.tls_record.outputs.response_file }}"
            ),
            2,
        )
        self.assertNotIn("prepare-domain-tls-restore.py", self.workflow)

    def test_existing_and_non_iac_restore_use_the_same_exact_owner(self) -> None:
        owner = (
            "uses: ai-workspace-infra/playbooks/.github/actions/"
            f"caddy-certificate-restore@{OWNER_SHA}"
        )
        self.assertEqual(self.workflow.count(owner), 2)
        self.assertNotIn("ref: 14f6196bbf69b78d07f1adb9fb8c97bc816a485b", self.workflow)
        self.assertNotIn("caddy-restore-playbooks/caddy_certificate_restore.yml", self.workflow)
        non_iac_restore = self.workflow.index(
            "- name: Restore domain TLS with pinned Playbooks owner",
            self.workflow.index("- name: Render non-IaC Agent Proxy inventory"),
        )
        deploy = self.workflow.index("- name: Deploy non-IaC Agent Proxy services")
        self.assertLess(non_iac_restore, deploy)

    def test_unaccepted_legacy_restore_remains_frozen(self) -> None:
        legacy_path = ".github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh"
        self.assertTrue((ROOT / legacy_path).is_file())
        registry = (ROOT / "scripts/ci/control-plane-legacy.yaml").read_text()
        self.assertIn(legacy_path, registry)
        self.assertNotIn(legacy_path, self.workflow)
        for fallback in (
            ".github/scripts/platform-ops/deploy/prepare-domain-tls-restore.py",
            ".github/scripts/platform-ops/deploy/platform-ops_deploy_render-non-iac-agent-proxy-inventory.py",
        ):
            self.assertTrue((ROOT / fallback).is_file())
            self.assertNotIn(Path(fallback).name, self.workflow)


if __name__ == "__main__":
    unittest.main()
