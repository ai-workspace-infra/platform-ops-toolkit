"""Control-plane input/cleanup and immutable owner wiring; no host execution."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock

ROOT = Path(__file__).resolve().parents[3]
ADAPTER = ROOT / '.github/scripts/platform-ops/deploy/prepare-domain-tls-restore.py'
spec = importlib.util.spec_from_file_location('prepare', ADAPTER)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
OWNER = '14f6196bbf69b78d07f1adb9fb8c97bc816a485b'


class TLSCallerTest(unittest.TestCase):
    def environment(self):
        return {'MATRIX_HOST': 'agent-proxy-uat', 'DOMAIN_TLS_DIR': '/etc/xcontrol/tls/example.test'}

    def record(self):
        return {field: base64.b64encode(('synthetic PEM ' + field).encode()).decode()
                for field in ['tls_fullchain_pem_b64', 'tls_cert_pem_b64', 'tls_key_pem_b64',
                              'tls_ca_pem_b64', 'tls_trust_bundle_pem_b64']}

    def test_both_callers_pin_same_owner_and_cleanup_before_deploy(self):
        source = (ROOT / '.github/workflows/selfhost-orchestrator.yml').read_text()
        for marker, deploy in [('Restore domain TLS state from Vault before Caddy can issue', 'Bootstrap node according to CMDB role'),
                               ('Restore domain TLS state to non-IaC node', 'Deploy non-IaC Agent Proxy services')]:
            start = source.index('- name: ' + marker)
            end = source.index('- name: ' + deploy, start)
            segment = source[start:end]
            self.assertIn('prepare-domain-tls-restore.py', segment)
            self.assertIn('ref: ' + OWNER, segment)
            self.assertIn('path: caddy-restore-playbooks', segment)
            self.assertIn('caddy-restore-playbooks/caddy_certificate_restore.yml', segment)
            self.assertIn('always() && steps.tls_restore.outputs.vars_file', segment)
            self.assertNotIn('platform-ops_deploy_base_restore-caddy-certs.sh', segment)
            self.assertLess(segment.index('ref: ' + OWNER), segment.index('ansible-playbook'))
        self.assertIn('ansible-playbook -i cmdb/inventory.ini', source)
        self.assertIn('ansible-playbook -i "${{ runner.temp }}/external-agent-proxy-inventory.yml"', source)
        self.assertIn('PreferredAuthentications=publickey,password', source)

    def test_expired_or_incomplete_backup_skips_without_host_changes(self):
        record = self.record()
        record['not_after_epoch'] = int(time.time()) - 1
        self.assertEqual((None, 'renewal-margin'), prepare.material_vars(record, self.environment()))
        record.pop('tls_ca_pem_b64')
        self.assertEqual((None, 'incomplete-backup'), prepare.material_vars(record, self.environment()))

    def test_input_validation_and_pem_contract(self):
        variables, reason = prepare.material_vars(self.record(), self.environment())
        self.assertEqual('ready', reason)
        self.assertEqual(1209600, variables['caddy_certificate_restore_min_validity_seconds'])
        self.assertEqual(5, len(variables['caddy_certificate_restore_material']))
        for target, directory in [('all', '/etc/xcontrol/tls/../escape'), ('host:*', '/etc/xcontrol/tls/example')]:
            with self.assertRaises(ValueError):
                prepare.material_vars(self.record(), {'MATRIX_HOST': target, 'DOMAIN_TLS_DIR': directory})

    def test_runtime_file_is_private_and_token_revoked(self):
        with tempfile.TemporaryDirectory() as temporary:
            env = dict(self.environment(), RUNNER_TEMP=temporary, GITHUB_OUTPUT=temporary + '/outputs',
                       VAULT_ADDR='https://vault.example.test', VAULT_CADDY_PATH='kv/data/uat/domains/example.test',
                       VAULT_ROLE='uat-role', ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example.test/token?test=1',
                       ACTIONS_ID_TOKEN_REQUEST_TOKEN='synthetic-request')
            calls = [{'value': 'synthetic-jwt'}, {'auth': {'client_token': 'synthetic-vault-token'}},
                     {'data': {'data': self.record()}}]
            with patch.dict(os.environ, env), patch.object(prepare, 'request', side_effect=calls), patch.object(prepare, 'urlopen') as revoke:
                revoke.return_value.__enter__.return_value = MagicMock()
                prepare.main()
            output = Path(env['GITHUB_OUTPUT']).read_text()
            self.assertIn('restore_required=true', output)
            filename = output.split('vars_file=', 1)[1].splitlines()[0]
            self.assertEqual(0o600, Path(filename).stat().st_mode & 0o777)
            self.assertEqual('agent-proxy-uat', json.loads(Path(filename).read_text())['caddy_certificate_restore_target'])
            self.assertEqual('https://vault.example.test/v1/auth/token/revoke-self', revoke.call_args.args[0].full_url)
            self.assertNotIn('synthetic PEM', output)


if __name__ == '__main__':
    unittest.main()
