#!/usr/bin/env python3
"""Regression checks for non-IaC domain TLS restoration."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NonIaCTLSRestoreContractTest(unittest.TestCase):
    def test_workflow_restores_tls_before_non_iac_deploy(self) -> None:
        workflow = (ROOT / ".github/workflows/selfhost-orchestrator.yml").read_text()
        restore = workflow.index("- name: Restore domain TLS state to non-IaC node")
        deploy = workflow.index("- name: Deploy non-IaC Agent Proxy services")
        self.assertLess(restore, deploy)
        self.assertIn(
            "RESTORE_INVENTORY_FILE: ${{ runner.temp }}/ph-agent-proxy-inventory.yml",
            workflow[restore:deploy],
        )

    def test_restore_script_supports_password_inventory_transport(self) -> None:
        script = (
            ROOT
            / ".github/scripts/platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh"
        ).read_text()
        self.assertIn('ansible-inventory -i "${RESTORE_INVENTORY_FILE}"', script)
        self.assertIn("ssh_command=(sshpass -e ssh)", script)
        self.assertIn('"${ssh_command[@]}" "${ssh_opts[@]}"', script)


if __name__ == "__main__":
    unittest.main()
