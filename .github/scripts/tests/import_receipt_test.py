import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('import_receipt', ROOT / '.github/scripts/environment-upgrade/import_receipt.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ImportReceiptTests(unittest.TestCase):
    def setUp(self):
        self.config = dict(dry_run=False, accounts_transport='direct', accounts_target_host='web-saas-uat', caller_run_id='42')
        self.inputs = dict(environment='uat', correlation_id='data-exact', accounts_ref='a'*40, config_json=json.dumps(self.config))
        self.run = dict(id=123, run_attempt=1)
        self.receipt = dict(schema='uat-data-import/v1', environment='uat', correlation_id='data-exact',
                            run_id='123', run_attempt='1', owner_sha='b'*40, accounts_ref='a'*40, accounts_sha='a'*40,
                            dry_run=False, target_host='web-saas-uat', caller_run_id='42', success=True,
                            runtime=dict(phase='target_verify', category='success', write_state='verified', convergence_verified=True))

    def validate(self):
        return module.validate(self.receipt, self.inputs, self.run, 'b'*40)

    def test_applied_convergence(self):
        self.assertTrue(self.validate()['success'])

    def test_unknown_runtime_fields_are_not_published(self):
        self.receipt['runtime']['raw'] = 'synthetic-secret'
        self.assertNotIn('synthetic-secret', json.dumps(self.validate()))

    def test_preview_is_distinct(self):
        self.config['dry_run'] = True
        self.inputs['config_json'] = json.dumps(self.config)
        self.receipt.update(dry_run=True, runtime=dict(phase='target_preview', category='success', write_state='not_attempted', convergence_verified=False))
        self.assertTrue(self.validate()['dry_run'])

    def test_wrong_identity_never_releases_parent(self):
        for key in ('environment', 'correlation_id', 'run_id', 'run_attempt', 'owner_sha', 'accounts_ref', 'accounts_sha', 'target_host', 'caller_run_id'):
            original = self.receipt[key]
            self.receipt[key] = 'wrong'
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate()
            self.receipt[key] = original

    def test_missing_receipt_fields_failed_or_partial_import(self):
        for runtime in ({}, dict(phase='target_apply', category='success', write_state='unverified', convergence_verified=False),
                        dict(phase='target_verify', category='execution_failed', write_state='unverified', convergence_verified=False)):
            self.receipt['runtime'] = runtime
            with self.assertRaises(ValueError):
                self.validate()

    def test_boolean_must_not_be_integer_or_string(self):
        for value in (0, 'false', None):
            self.receipt['dry_run'] = value
            with self.assertRaises(ValueError):
                self.validate()


if __name__ == '__main__':
    unittest.main()
