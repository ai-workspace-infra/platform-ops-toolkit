#!/usr/bin/env python3
"""Behavior tests using a local Vault double; no real credentials or server."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/cloud/bootstrap/iam/bootstrap_identity_kv.sh'
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a=sys.argv[1:]
log=Path(os.environ['MOCK_LOG'])
with log.open('a') as f: f.write(json.dumps(a)+'\n')
mode=os.environ.get('MOCK_MODE','existing')
if a[:2]==['token','lookup']:
 sys.exit(1 if mode=='auth' else 0)
if a[:2]==['kv','get']:
 if mode in ('missing','denied','timeout','tls'):
  print({'missing':'No value found at test','denied':'permission denied','timeout':'timeout','tls':'TLS verification failed'}[mode],file=sys.stderr);sys.exit(1)
 fields=json.loads(os.environ['MOCK_FIELDS'])
 print(json.dumps({'data':{'metadata':{'version':7},'data':fields}}));sys.exit(0)
if a[:2]==['kv','put']:
 payload=Path(a[-1][1:])
 assert payload.stat().st_mode & 0o777 == 0o600
 assert payload.parent.stat().st_mode & 0o777 == 0o700
 if mode=='conflict': print('CAS mismatch',file=sys.stderr);sys.exit(1)
 Path(os.environ['MOCK_RESULT']).write_text(Path(a[-1][1:]).read_text());sys.exit(0)
sys.exit(2)
'''


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        vault = self.path / 'vault'
        vault.write_text(MOCK)
        vault.chmod(0o700)
        self.log = self.path / 'calls.jsonl'
        self.result = self.path / 'result.json'
        self.payload = self.path / 'payload.json'
        self.fields = dict(issuer='https://idp.example.test', audience='test',
                           oidc_provider_arn='arn:test:provider', role_arn='arn:test:role',
                           subject='exact-test-subject', client_secret='SENTINEL_FAKE_SECRET')
        self.payload.write_text(json.dumps(self.fields))
        self.payload.chmod(0o600)
        self.env = dict(os.environ, PATH=str(self.path)+os.pathsep+os.environ['PATH'],
                        TMPDIR=str(self.path), VAULT_ADDR='https://vault.example.test',
                        VAULT_TOKEN='FAKE_TEST_TOKEN', VAULT_MOUNT='kv',
                        MOCK_LOG=str(self.log), MOCK_RESULT=str(self.result),
                        MOCK_FIELDS=json.dumps(dict(self.fields, retained='keep')))

    def run_script(self, mode='existing', action='--apply', script=SCRIPT, extra=None):
        self.env['MOCK_MODE'] = mode
        args = ['bash', str(script), '--env', 'uat', '--account', 'test-account',
                '--purpose', 'workload', action]
        if script == SCRIPT:
            args += ['--integration', 'aws']
        if action == '--apply':
            args += ['--payload-file', str(self.payload)]
        proc = subprocess.run(args+(extra or []), env=self.env, capture_output=True, text=True)
        self.assertNotIn('SENTINEL_FAKE_SECRET', proc.stdout+proc.stderr)
        self.assertNotIn('FAKE_TEST_TOKEN', proc.stdout+proc.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        self.assertFalse(any('SENTINEL_FAKE_SECRET' in str(call) for call in calls))
        self.assertFalse(list(self.path.glob('identity-kv*')), 'temporary secret files leaked')
        return proc, calls

    def writes(self, calls):
        return [call for call in calls if call[:2] == ['kv', 'put']]

    def test_create_and_update_cas_preserve_fields(self):
        for mode, cas in [('missing', '-cas=0'), ('existing', '-cas=7')]:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                proc, calls = self.run_script(mode)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(len(self.writes(calls)), 1)
                self.assertIn(cas, self.writes(calls)[0])
                self.assertIn('iam/uat/aws/test-account/workload', self.writes(calls)[0])
                data = json.loads(self.result.read_text())
                self.assertEqual(data['subject'], self.fields['subject'])
                if mode == 'existing': self.assertEqual(data['retained'], 'keep')

    def test_read_and_auth_failures_never_write(self):
        for mode in ['denied', 'timeout', 'tls', 'auth']:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                proc, calls = self.run_script(mode)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(self.writes(calls), [])

    def test_cas_conflict_no_retry_or_overwrite(self):
        proc, calls = self.run_script('conflict')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(len(self.writes(calls)), 1)
        self.assertFalse(self.result.exists())

    def test_check_is_read_only(self):
        for mode, success in [('existing', True), ('missing', False), ('denied', False)]:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                proc, calls = self.run_script(mode, '--check')
                self.assertEqual(proc.returncode == 0, success)
                self.assertEqual(self.writes(calls), [])
        self.env['MOCK_FIELDS'] = '{}'
        proc, calls = self.run_script(action='--check')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.writes(calls), [])

    def test_invalid_inputs_fail_before_vault(self):
        for payload in ['[]', '{}', '{broken']:
            with self.subTest(payload=payload):
                self.payload.write_text(payload)
                proc, calls = self.run_script()
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(calls, [])
        self.payload.write_text(json.dumps(self.fields))
        self.payload.chmod(0o644)
        proc, calls = self.run_script()
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(calls, [])

        self.payload.chmod(0o600)
        proc, calls = self.run_script(extra=['--account', '../prod'])
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(calls, [])

    def test_reject_unsupported_integration_or_purpose(self):
        for extra in [['--integration', 'unknown'], ['--purpose', 'application']]:
            with self.subTest(extra=extra):
                proc, calls = self.run_script(extra=extra)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(calls, [])

    def test_all_wrappers_route_to_expected_provider(self):
        wrappers = {
            'gcp': 'gcp/bootstrap_gcp_iam_kv.sh',
            'aws': 'aws/bootstrap_aws_iam_kv.sh',
            'linode': 'Akamai-Cloud/bootstrap_linode_sso_kv.sh',
            'vultr': 'vultr-VPS/bootstrap_vultr_sso_kv.sh',
            'ucloud-global': 'ucloud/bootstrap_ucloud_global_sso_kv.sh',
            'grafana': 'iam/bootstrap_grafana_oidc_kv.sh',
        }
        self.env['MOCK_FIELDS'] = json.dumps(dict(self.fields, api_credential_ref='kv/CICD/uat/test',
            workload_identity_provider='projects/test/provider', service_account='test@example.test',
            client_id='test', redirect_uri='https://app.example.test/callback', role_claim='roles'))
        for provider, relative in wrappers.items():
            with self.subTest(provider=provider):
                self.log.unlink(missing_ok=True)
                proc, calls = self.run_script(action='--check',
                    script=ROOT / 'scripts/cloud/bootstrap' / relative,
                    extra=['--purpose', 'application'] if provider == 'grafana' else [])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                purpose = 'application' if provider == 'grafana' else 'workload'
                self.assertIn(f'iam/uat/{provider}/test-account/{purpose}', calls[-1])
                self.assertEqual(self.writes(calls), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
