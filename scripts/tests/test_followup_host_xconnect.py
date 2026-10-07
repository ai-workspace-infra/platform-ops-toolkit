import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
OWNER = '9d585e147348800b1603c4f7b0d8a6bcf0546007'


class FollowupHostXConnectCallerTests(unittest.TestCase):
    def test_runtime_control_uses_fixed_owner_and_vault_reviewed_host_keys(self):
        source = (ROOT / '.github/workflows/xconnect-runtime-control.yml').read_text()
        self.assertIn(f'xconnect-lab-runtime@{OWNER}', source)
        self.assertIn(f'owner-sha: {OWNER}', source)
        self.assertIn('kv/data/CICD/uat SSH_PRIVATE_DEPLOY_KEY_B64', source)
        self.assertIn('kv/data/CICD/uat SSH_KNOWN_HOSTS_B64', source)
        self.assertIn('known-hosts-file:', source)
        self.assertIn('name: xconnect-runtime-owner-${{ github.run_id }}-${{ github.run_attempt }}', source)
        self.assertIn('if: ${{ always() }}', source)
        self.assertNotIn('accept-new', source)
        self.assertNotIn('ssh-keyscan', source)
        self.assertNotIn('ansible-playbook', source)
        self.assertNotIn('playbooks_ref:', source)

    def test_runtime_control_exposes_exact_xhttp_contract(self):
        source = (ROOT / '.github/workflows/xconnect-runtime-control.yml').read_text()
        self.assertIn('options: [gateway_verify, one_verify, xhttp_verify]', source)
        for value in ('xhttp_config_path', 'xhttp_remote_address', 'xhttp_server_name',
                      'xhttp_path', 'xhttp_mode', 'xhttp_host'):
            self.assertIn(value, source)
        self.assertIn("if [[ \"$OPERATION\" == xhttp_verify ]]", source)

    def test_vault_claim_is_exact_main_and_uat_for_both_callers(self):
        role = json.loads((ROOT / 'scripts/vault/roles/github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab.json').read_text())
        claims = role['bound_claims']
        self.assertEqual(claims['ref'], 'refs/heads/main')
        self.assertEqual(claims['environment'], 'uat')
        self.assertEqual(set(claims['job_workflow_ref']), {
            'ai-workspace-infra/platform-ops-toolkit/.github/workflows/xconnect-zero-cloud.yaml@refs/heads/main',
            'ai-workspace-infra/platform-ops-toolkit/.github/workflows/xconnect-runtime-control.yml@refs/heads/main',
        })

    def test_zero_cloud_routes_safe_host_callers_to_fixed_owner(self):
        source = (ROOT / '.github/workflows/xconnect-zero-cloud.yaml').read_text()
        self.assertIn(f'service-probes@{OWNER}', source)
        self.assertIn(f'xconnect-node-observation@{OWNER}', source)
        self.assertIn(f'xconnect-lab-runtime@{OWNER}', source)
        self.assertIn('operation: gateway_reconcile', source)
        target_record = 'kv/data/prod/ulighthost-xconnect/tw-xconnect.svc.plus'
        self.assertIn(f'{target_record} ssh_private_key_b64 | EXTERNAL_GATEWAY_SSH_PRIVATE_KEY_B64', source)
        self.assertIn(f'{target_record} known_hosts_b64 | SSH_KNOWN_HOSTS_B64', source)
        self.assertNotIn('kv/data/CICD/uat SSH_KNOWN_HOSTS_B64', source)
        reconcile = source[source.index('  reconcile_mesh:'):source.index('  cleanup:')]
        self.assertIn('environment: uat', reconcile)
        self.assertNotIn('accept-new', reconcile)
        self.assertNotRegex(reconcile, r'(?m)^\s+ssh\s')

    def test_frontend_boundary_probes_are_fixed_owner_calls(self):
        source = (ROOT / '.github/workflows/serverless-orchestrator.yml').read_text()
        for operation in ('public-chain', 'frontend-assets'):
            match = re.search(
                rf'uses: ai-workspace-infra/playbooks/\.github/actions/service-probes@([0-9a-f]{{40}})\n'
                rf'\s+with:\n\s+operation: {operation}', source)
            self.assertIsNotNone(match, operation)
            self.assertEqual(match.group(1), OWNER)

    def test_called_legacy_lab_bytes_remain_until_real_uat(self):
        workflow = (ROOT / '.github/workflows/xconnect-zero-cloud.yaml').read_text()
        for stage in ('setup', 'bootstrap', 'gateway', 'one', 'verify'):
            self.assertIn(f'run.sh {stage}', workflow)
        for path in (
            '.github/scripts/xconnect-lab/deploy.sh',
            '.github/scripts/xconnect-lab/verify-xhttp-runtime.sh',
            '.github/scripts/xconnect-lab/node-observation.sh',
        ):
            self.assertTrue((ROOT / path).is_file(), path)


if __name__ == '__main__':
    unittest.main()
