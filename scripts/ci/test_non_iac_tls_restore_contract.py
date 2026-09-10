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
        self.assertIn("PreferredAuthentications=publickey,password", script)
        self.assertIn("ssh_opts=(-i ~/.ssh/id_deploy", script)
        self.assertIn('"${ssh_command[@]}" "${ssh_opts[@]}"', script)

    def test_workflow_preserves_key_access_before_observability_hardening(self) -> None:
        workflow = (ROOT / ".github/workflows/selfhost-orchestrator.yml").read_text()
        preserve = workflow.index("- name: Preserve deploy-key access on non-IaC node")
        observe = workflow.index("- name: Deploy Observability Agent for non-IaC Agent Proxy")
        self.assertLess(preserve, observe)
        segment = workflow[preserve:observe]
        self.assertIn("prepare_non_iac_ssh_access.yml", segment)
        self.assertIn(
            'ssh-keygen -y -f "${{ steps.runner.outputs.deploy_key_file }}"',
            segment,
        )
        self.assertIn(
            "XCONNECT_DEPLOY_KEY_FILE: ${{ steps.runner.outputs.deploy_key_file }}",
            workflow,
        )
        self.assertIn(
            "XCONNECT_INVENTORY_FILE: ${{ runner.temp }}/ph-agent-proxy-bootstrap-inventory.yml",
            workflow,
        )
        self.assertIn(
            "PreferredAuthentications=password",
            workflow[preserve:observe],
        )
        self.assertIn(
            "Render deploy-key inventory for non-IaC node",
            workflow[preserve:observe],
        )

        renderer = (
            ROOT
            / ".github/scripts/platform-ops/deploy/platform-ops_deploy_render-non-iac-agent-proxy-inventory.py"
        ).read_text()
        self.assertIn('host_vars["ansible_ssh_private_key_file"] = deploy_key_file', renderer)
        self.assertIn(
            'host = node_secret.get("public_ipv4") or node_secret.get("ip") or selected.get("ansible_host")',
            renderer,
        )
        self.assertIn(
            'user = node_secret.get("ansible_user") or selected.get("ansible_user")',
            renderer,
        )
        self.assertIn(
            'password = node_secret.get("SSH_PASSWORD") or node_secret.get("ansible_password")',
            renderer,
        )


if __name__ == "__main__":
    unittest.main()
