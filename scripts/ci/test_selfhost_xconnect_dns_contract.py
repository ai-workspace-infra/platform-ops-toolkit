#!/usr/bin/env python3
"""Regression checks for PROD XConnect regional entrypoint DNS."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SelfhostXConnectDNSContractTest(unittest.TestCase):
    def test_prod_dns_job_reconciles_every_regional_entrypoint(self) -> None:
        workflow = (ROOT / ".github/workflows/selfhost-orchestrator.yml").read_text()
        checkout = workflow.index("- name: Checkout GitOps XConnect topology")
        reconcile = workflow.index("- name: Reconcile production XConnect regional entrypoints")
        self.assertLess(checkout, reconcile)
        step = workflow[reconcile:]
        self.assertIn("for pool in jp us hk ph; do", step)
        self.assertIn("ansible-playbook reconcile_xconnect_entrypoint.yml", step)
        self.assertIn("XCONNECT_CMDB_FILE:", step)
        self.assertIn("xconnect-regional-pools.yaml", workflow)
        self.assertIn("xconnect-regional-pool.yaml", workflow)
        self.assertNotIn("ulighthost-xconnect.yaml", workflow)
        vault_step = workflow[workflow.index("- name: Load Vault secrets for DNS"):reconcile]
        self.assertIn("exportToken: true", vault_step)


if __name__ == "__main__":
    unittest.main()
