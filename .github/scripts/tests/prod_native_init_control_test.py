"""Native init evidence/independent review fixtures; no production access."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
import yaml

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('native_init_control', ROOT / '.github/scripts/prod-selfhost/native_init_control.py')
CONTROL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROL)


class NativeInitControlTests(unittest.TestCase):
    def fixture(self, directory):
        receipt = dict(stage='database_standby', environment='prod', host='web-saas-prod',
            gitops_commit='a' * 40, postgres_major=17, independent_disk_verified=True,
            writers_paused=True, schema_initialized=False, database_cutover_approved=False)
        raw = json.dumps(receipt).encode()
        archive = Path(directory) / 'standby.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('prod-native-standby-receipt.json', raw)
        source = dict(run_id=123, run_attempt=1, toolkit_commit='b' * 40, release_tag='v2026.10.07-r2',
            artifact_id=456, artifact_digest='sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest(),
            receipt_sha256=hashlib.sha256(raw).hexdigest())
        contract = dict(standby_accepted=True, gitops_commit='a' * 40, standby=source)
        run = dict(id=123, run_attempt=1, repository={'full_name': CONTROL.BASE.REPOSITORY},
            event='workflow_dispatch', status='completed', conclusion='success',
            head_sha='b' * 40, head_branch=source['release_tag'], workflow_id=789)
        workflow = dict(id=789, path='.github/workflows/selfhost-orchestrator.yml')
        artifact = dict(id=456, name='prod-native-standby-receipt', expired=False,
            workflow_run={'id': 123, 'head_sha': 'b' * 40}, digest=source['artifact_digest'],
            size_in_bytes=archive.stat().st_size)
        return contract, run, workflow, artifact, archive

    def test_exact_successful_standby_and_original_receipt_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            contract, run, workflow, artifact, archive = self.fixture(directory)
            CONTROL.validate_standby(contract, run, workflow, artifact)
            CONTROL.validate_receipt(contract, archive)

    def test_pending_failed_foreign_or_rerun_standby_is_refused(self):
        for key, value in [('conclusion', 'failure'), ('event', 'pull_request'), ('run_attempt', 2),
                           ('head_sha', 'c' * 40), ('head_branch', 'main')]:
            with tempfile.TemporaryDirectory() as directory:
                contract, run, workflow, artifact, _ = self.fixture(directory)
                run[key] = value
                with self.assertRaises(ValueError):
                    CONTROL.validate_standby(contract, run, workflow, artifact)
        with tempfile.TemporaryDirectory() as directory:
            contract, run, workflow, artifact, _ = self.fixture(directory)
            contract['standby_accepted'] = False
            with self.assertRaises(ValueError):
                CONTROL.validate_standby(contract, run, workflow, artifact)

    def test_archive_checksum_and_schema_state_are_not_trusted_blindly(self):
        for key, value in [('schema_initialized', True), ('writers_paused', False),
                           ('postgres_major', 16), ('database_cutover_approved', True)]:
            with tempfile.TemporaryDirectory() as directory:
                contract, _, _, _, archive = self.fixture(directory)
                with zipfile.ZipFile(archive) as zipped:
                    receipt = json.loads(zipped.read('prod-native-standby-receipt.json'))
                receipt[key] = value
                raw = json.dumps(receipt).encode()
                with zipfile.ZipFile(archive, 'w') as zipped:
                    zipped.writestr('prod-native-standby-receipt.json', raw)
                contract['standby']['artifact_digest'] = 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
                contract['standby']['receipt_sha256'] = hashlib.sha256(raw).hexdigest()
                with self.assertRaises(ValueError):
                    CONTROL.validate_receipt(contract, archive)

    def review(self):
        environment = dict(name='prod', id=8, protection_rules=[dict(type='required_reviewers', prevent_self_review=True,
            reviewers=[{'type': 'User', 'reviewer': {'login': 'reviewer'}}])])
        run = dict(id=999, run_attempt=1, event='workflow_dispatch', head_sha='d' * 40,
            head_branch='v2026.10.07-r3', repository={'full_name': CONTROL.BASE.REPOSITORY},
            actor={'login': 'starter'}, triggering_actor={'login': 'starter'})
        reviews = [dict(state='approved', user={'login': 'reviewer'}, environments=[{'id': 8, 'name': 'prod'}])]
        return environment, run, reviews

    def validate_review(self, environment, run, reviews):
        return CONTROL.validate_data_review(environment, run, reviews, '999', 'd' * 40, 'refs/tags/v2026.10.07-r3')

    def test_current_independent_review_is_required(self):
        environment, run, reviews = self.review()
        self.validate_review(environment, run, reviews)
        for change in ('disabled', 'self', 'missing', 'foreign-env', 'rerun'):
            e, r, v = self.review()
            if change == 'disabled':
                e['protection_rules'][0]['prevent_self_review'] = False
            if change == 'self':
                v[0]['user']['login'] = 'starter'
            if change == 'missing':
                v = []
            if change == 'foreign-env':
                v[0]['environments'][0]['id'] = 9
            if change == 'rerun':
                r['run_attempt'] = 2
            with self.assertRaises(ValueError):
                self.validate_review(e, r, v)

    def test_initialization_covers_exact_52_table_manifest(self):
        config = json.loads((ROOT / '.github/config/prod-native-init.json').read_text())
        CONTROL.validate_initialization(config['initialization'])
        for key, value in [('image', 'accounts:latest'), ('image_digest', 'latest'),
                           ('business_table_count', 3), ('database', 'postgres')]:
            spec = copy.deepcopy(config['initialization'])
            spec[key] = value
            with self.assertRaises(ValueError):
                CONTROL.validate_initialization(spec)

    def test_dispatch_does_not_accept_overrides_or_implicit_apply(self):
        event = {'inputs': dict(operation='native-init-plan', vault_env_path='prod', target_domains='web-saas',
            cloud_provider='gcp-cloud', cloud_account='xworktech', target_domain_base='svc.plus',
            dns_mode='none', runner_type='ubuntu-latest', offline_mode='off')}
        args = ('refs/tags/v2026.10.07-r3', 'd' * 40, CONTROL.BASE.REPOSITORY, '1')
        self.assertTrue(CONTROL.validate_inputs(event, *args))
        event['inputs']['operation'] = 'native-init'
        self.assertFalse(CONTROL.validate_inputs(event, *args))
        event['inputs']['dns_mode'] = 'prod-cutover'
        with self.assertRaises(ValueError):
            CONTROL.validate_inputs(event, *args)

    def test_review_precedes_credentials_and_cleanup_precedes_artifacts(self):
        config = json.loads((ROOT / '.github/config/prod-native-init.json').read_text())
        workflow = yaml.safe_load((ROOT / '.github/workflows/selfhost-orchestrator.yml').read_text())
        job = workflow['jobs']['native_prod_init']
        self.assertEqual(job['environment'], 'prod')
        steps = job['steps']
        gate = next(i for i, step in enumerate(steps) if step.get('id') == 'native_init_control')
        vault = next(i for i, step in enumerate(steps) if step.get('id') == 'native_vault')
        self.assertLess(gate, vault)
        self.assertIs(steps[vault]['with'].get('exportEnv'), False)
        remote = [step['uses'] for step in steps if '.github/actions/prod-' in step.get('uses', '')]
        self.assertEqual(remote, ['ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@' + config['iac_commit'],
            'ai-workspace-infra/playbooks/.github/actions/prod-native-init@' + config['playbooks_commit'],
            'ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@' + config['iac_commit']])
        owner = next(step for step in steps if '/prod-native-init@' in step.get('uses', ''))
        self.assertEqual(owner['with']['dry_run'], '${{ steps.native_init_control.outputs.dry_run }}')
        self.assertEqual(owner['with']['data_gate_verified'], '${{ steps.native_init_control.outputs.data_gate_verified }}')
        close = next(i for i, step in enumerate(steps) if step.get('with', {}).get('phase') == 'close')
        self.assertIn('always()', steps[close]['if'])
        for i, step in enumerate(steps):
            if step.get('uses', '').startswith('actions/upload-artifact@'):
                self.assertGreater(i, close)
                self.assertNotIn('access', step['with']['path'])


if __name__ == '__main__':
    unittest.main()
