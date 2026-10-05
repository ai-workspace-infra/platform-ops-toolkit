import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/xconnect-runtime-control.yml'


class XConnectRuntimeControlWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.source = WORKFLOW.read_text()

    def test_caller_is_uat_only_and_pins_owner_sha(self):
        self.assertIn('environment: uat', self.source)
        self.assertIn('94b9ca010efb1eeb62469f791a910dd361f1abae', self.source)
        self.assertIn('playbooks_ref must be a full immutable SHA', self.source)
        self.assertNotIn('prod', self.source.lower())

    def test_caller_delegates_host_service_execution_to_playbooks(self):
        self.assertIn('ai-workspace-infra/playbooks', self.source)
        self.assertIn('playbooks/xconnect-lab-runtime.yml', self.source)
        self.assertIn('ansible-playbook', self.source)
        self.assertNotIn('terraform', self.source.lower())
        self.assertNotIn('cloudflare', self.source.lower())
        self.assertNotIn('aws ', self.source.lower())

    def test_only_read_only_verification_operations_are_exposed(self):
        self.assertIn('options: [gateway_verify, one_verify]', self.source)
        self.assertNotIn('gateway_identity, gateway, one,', self.source)
        self.assertIn('Remove runner-private SSH identity', self.source)


if __name__ == '__main__':
    unittest.main()
