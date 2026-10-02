#!/usr/bin/env python3
"""Test real GitOps identity refs against the bootstrap behavior, using fake KV."""
import argparse
import json
from pathlib import Path
import subprocess
import unittest

import test_identity_bootstrap as bootstrap

parser = argparse.ArgumentParser()
parser.add_argument('--gitops-root', type=Path, required=True)
args = parser.parse_args()


class CrossRepositoryTest(unittest.TestCase):
    def test_manifest_identity_refs_are_readable_by_bootstrap(self):
        manifests = sorted((args.gitops_root / 'resources').glob('**/iam/identity-integrations.yaml'))
        self.assertTrue(manifests, 'no identity manifests found')
        for manifest in manifests:
            proc = subprocess.run(['ruby', '-ryaml', '-rjson', '-e',
                'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: false))', str(manifest)],
                capture_output=True, text=True, check=True)
            doc = json.loads(proc.stdout)
            for integration in doc['spec']['integrations']:
                for flow in integration['flows']:
                    if flow['protocol'] == 'vault-api-token':
                        continue  # existing API bootstrap owns legacy CICD paths
                    with self.subTest(manifest=manifest.name, provider=integration['provider'], purpose=flow['purpose']):
                        fixture = bootstrap.BootstrapTests()
                        fixture.setUp()
                        self.addCleanup(fixture.doCleanups)
                        ref = flow['vault_ref']
                        parts = ref.split('/')
                        self.assertEqual(len(parts), 6)
                        _, namespace, environment, provider, account, purpose = parts
                        self.assertEqual(namespace, 'iam')
                        self.assertEqual(environment, doc['metadata']['environment'])
                        self.assertEqual(provider, integration['provider'])
                        self.assertEqual(purpose, flow['purpose'])
                        fake_fields = dict(fixture.fields, client_id='test',
                            workforce_pool_provider='test-workforce-provider',
                            workload_identity_provider='test-workload-provider',
                            service_account='test@example.test', entity_id='test-entity',
                            acs_url='https://sp.example.test/acs', saml_metadata_sha256='test-hash',
                            company_id='test-company', nameid_attribute='email',
                            redirect_uri='https://app.example.test/callback', role_claim='roles')
                        fixture.env['MOCK_FIELDS'] = json.dumps(fake_fields)
                        result, calls = fixture.run_script(action='--check', extra=[
                            '--integration', provider, '--env', environment,
                            '--account', account, '--purpose', purpose])
                        self.assertEqual(result.returncode, 0, result.stderr)
                        reads = [call for call in calls if call[:2] == ['kv', 'get']]
                        self.assertEqual(len(reads), 1)
                        self.assertEqual(reads[0][-1], ref.removeprefix('kv/'))
                        self.assertEqual(fixture.writes(calls), [])


if __name__ == '__main__':
    unittest.main(argv=['cross-repo'], verbosity=2)
