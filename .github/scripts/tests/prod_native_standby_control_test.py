"""Fictional control-plane fixtures; never accesses PROD or cloud APIs."""
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
SPEC = importlib.util.spec_from_file_location('native_control', ROOT / '.github/scripts/prod-selfhost/native_standby_control.py')
CONTROL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROL)


class NativeControlTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        cmdb = {'environment': 'prod', 'project_id': 'open-platform-prod',
            'deploy_account': 'github-actions-prod@open-platform-prod.iam.gserviceaccount.com',
            'web-saas-prod': {'provider': 'gcp-cloud', 'zone': 'asia-east1-a', 'provisioning_model': 'STANDARD',
                'groups': ['web_saas'], 'ip': '192.0.2.1', 'ansible_user': 'fixture',
                'data_disk': {'id': 'projects/open-platform-prod/zones/asia-east1-a/disks/web-saas-prod-data', 'mount_path': '/data'}}}
        files = {'cmdb.json': json.dumps(cmdb).encode(), 'inventory.ini': b'[web_saas]\nweb-saas-prod\n'}
        archive = root / 'resource.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            for name, value in files.items():
                z.writestr(name, value)
        source = {'run_id': 123, 'run_attempt': 1, 'artifact_id': 456,
            'toolkit_commit': 'a' * 40, 'release_tag': 'v2026.10.06-r5',
            'artifact_digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest(),
            'cmdb_sha256': hashlib.sha256(files['cmdb.json']).hexdigest(),
            'inventory_sha256': hashlib.sha256(files['inventory.ini']).hexdigest()}
        contract = {'resource_accepted': True, 'resource': source}
        run = {'id': 123, 'run_attempt': 1, 'repository': {'full_name': CONTROL.REPOSITORY},
            'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success',
            'head_sha': 'a' * 40, 'head_branch': source['release_tag'], 'workflow_id': 789}
        workflow = {'id': 789, 'path': CONTROL.RESOURCE_WORKFLOW}
        artifact = {'id': 456, 'name': 'gcp-prod-web-saas-inventory', 'expired': False,
            'workflow_run': {'id': 123, 'head_sha': 'a' * 40},
            'digest': source['artifact_digest'], 'size_in_bytes': archive.stat().st_size}
        return contract, run, workflow, artifact, archive, files

    def test_original_artifact_bytes_are_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            contract, run, workflow, artifact, archive, files = self.fixture(d)
            CONTROL.validate_provenance(contract, run, workflow, artifact)
            destination = Path(d) / 'accepted'
            CONTROL.stage_archive(contract, archive, destination)
            self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, files)
            with self.assertRaises(ValueError):
                CONTROL.stage_archive(contract, archive, destination)

    def test_failed_pr_foreign_or_retried_runs_are_refused(self):
        for field, value in [('conclusion', 'failure'), ('event', 'pull_request'),
                ('head_sha', 'b' * 40), ('run_attempt', 2), ('head_branch', 'main')]:
            with tempfile.TemporaryDirectory() as d:
                c, r, w, a, _, _ = self.fixture(d)
                r[field] = value
                with self.assertRaises(ValueError):
                    CONTROL.validate_provenance(c, r, w, a)

    def test_wrong_workflow_artifact_digest_or_expiry_are_refused(self):
        for field, value in [('name', 'handwritten-cmdb'), ('digest', 'sha256:' + '0' * 64),
                             ('expired', True), ('id', 457)]:
            with tempfile.TemporaryDirectory() as d:
                c, r, w, a, _, _ = self.fixture(d)
                a[field] = value
                with self.assertRaises(ValueError):
                    CONTROL.validate_provenance(c, r, w, a)
        with tempfile.TemporaryDirectory() as d:
            c, r, w, a, _, _ = self.fixture(d)
            w['path'] = '.github/workflows/selfhost-orchestrator.yml'
            with self.assertRaises(ValueError):
                CONTROL.validate_provenance(c, r, w, a)
            c['resource_accepted'] = False
            with self.assertRaises(ValueError):
                CONTROL.validate_provenance(c, r, {'id': 789, 'path': CONTROL.RESOURCE_WORKFLOW}, a)

    def test_tampered_download_or_inventory_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            c, _, _, _, archive, _ = self.fixture(d)
            archive.write_bytes(archive.read_bytes() + b'changed')
            with self.assertRaises(ValueError):
                CONTROL.stage_archive(c, archive, Path(d) / 'accepted')
        with tempfile.TemporaryDirectory() as d:
            c, _, _, _, archive, _ = self.fixture(d)
            c['resource']['inventory_sha256'] = '0' * 64
            with self.assertRaises(ValueError):
                CONTROL.stage_archive(c, archive, Path(d) / 'accepted')

    def test_archive_path_traversal_and_extra_files_are_refused(self):
        for name in ('../outside', 'private-key', '/tmp/outside'):
            with tempfile.TemporaryDirectory() as d:
                c, _, _, _, archive, _ = self.fixture(d)
                with zipfile.ZipFile(archive, 'a') as z:
                    z.writestr(name, 'fictional')
                c['resource']['artifact_digest'] = 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
                with self.assertRaises(ValueError):
                    CONTROL.stage_archive(c, archive, Path(d) / 'accepted')

    def valid_inputs(self):
        return {'inputs': {'operation': 'native-standby', 'vault_env_path': 'prod', 'target_domains': 'web-saas',
            'cloud_provider': 'gcp-cloud', 'cloud_account': 'xworktech', 'target_domain_base': 'svc.plus',
            'dns_mode': 'none', 'runner_type': 'ubuntu-latest', 'offline_mode': 'off'}}

    def test_explicit_tag_and_canonical_control_target(self):
        CONTROL.validate_inputs(self.valid_inputs(), 'refs/tags/v2026.10.07-r1', 'a' * 40, CONTROL.REPOSITORY)
        for field, value in [('vault_env_path', 'uat'), ('vault_addr', 'https://unapproved.example'),
                ('dns_mode', 'prod-cutover'), ('source_ref', 'main'), ('deploy_tag', 'latest'),
                ('target_domains', 'all'), ('cloud_account', 'other')]:
            event = self.valid_inputs()
            event['inputs'][field] = value
            with self.assertRaises(ValueError):
                CONTROL.validate_inputs(event, 'refs/tags/v2026.10.07-r1', 'a' * 40, CONTROL.REPOSITORY)
        with self.assertRaises(ValueError):
            CONTROL.validate_inputs(self.valid_inputs(), 'refs/heads/main', 'a' * 40, CONTROL.REPOSITORY)

    def test_fixed_execution_owners_and_cleanup_precede_artifacts(self):
        wf = yaml.safe_load((ROOT / '.github/workflows/selfhost-orchestrator.yml').read_text())
        jobs = wf['jobs']
        job = jobs['native_prod_standby']
        self.assertEqual(job['environment'], 'prod')
        steps = job['steps']
        config = json.loads((ROOT / '.github/config/prod-native-standby.json').read_text())
        remote = [s['uses'] for s in steps if 'uses' in s and '.github/actions/prod-' in s['uses']]
        self.assertEqual(remote, [
            'ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@' + config['iac_commit'],
            'ai-workspace-infra/playbooks/.github/actions/prod-native-standby@' + config['playbooks_commit'],
            'ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@' + config['iac_commit']])
        close = next(i for i, s in enumerate(steps) if s.get('with', {}).get('phase') == 'close')
        self.assertIn('always()', steps[close]['if'])
        artifacts = [i for i, s in enumerate(steps) if s.get('uses', '').startswith('actions/upload-artifact@')]
        self.assertTrue(all(i > close for i in artifacts))
        for i in artifacts:
            path = steps[i]['with']['path']
            self.assertNotIn('access', path)
            self.assertNotIn('**', path)
        self.assertIn("operation != 'native-standby'", jobs['provision']['if'])
        self.assertIn("operation != 'native-standby'", jobs['deployment_summary']['if'])


if __name__ == '__main__':
    unittest.main()
