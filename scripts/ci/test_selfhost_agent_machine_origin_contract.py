#!/usr/bin/env python3
"""Regression checks for Agent Proxy machine API routing."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/selfhost-orchestrator.yml"


class SelfhostAgentMachineOriginContractTest(unittest.TestCase):
    def test_deployments_use_resolved_accounts_machine_origin(self) -> None:
        workflow = WORKFLOW.read_text()

        self.assertEqual(
            len(
                re.findall(
                    r"AGENT_CONTROLLER_URL:\s+\$\{\{ needs\.provision\.outputs\.agent_accounts_base_url \}\}",
                    workflow,
                )
            ),
            5,
        )
        self.assertIn(
            "ACCOUNTS_BASE_URL: ${{ needs.provision.outputs.agent_accounts_base_url }}",
            workflow,
        )

        # The public controller URL remains only where DNS and the release
        # summary need the customer-facing hostname.
        self.assertEqual(
            len(
                re.findall(
                    r"AGENT_CONTROLLER_URL:\s+\$\{\{ needs\.provision\.outputs\.agent_controller_url \}\}",
                    workflow,
                )
            ),
            2,
        )


if __name__ == "__main__":
    unittest.main()
