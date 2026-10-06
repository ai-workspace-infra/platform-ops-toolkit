"""Billing provenance and independent-review fixtures; no database/cloud access."""
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
LOADER = importlib.util.spec_from_file_location('native_billing_control', ROOT / '.github/scripts/prod-selfhost/native_billing_control.py')
CONTROL = importlib.util.module_from_spec(LOADER)
LOADER.loader.exec_module(CONTROL)


class BillingControlTests(unittest.TestCase):
    def fixture(self, directory):
        contract = json.loads((ROOT / '.github/config/prod-native-billing.json').read_text())
        spec = contract['initialization']
        receipt = dict(stage='native_schema_initialized', result='initialized', environment='prod',
            host='web-saas-prod', database='account', schema_initialized=True, business_rows=0,
            writers_paused=True, independent_disk_verified=True, database_cutover_approved=False,
            **{k:spec[k] for k in ('schema_sha256','migration_version','business_tables','accounts_commit','image_digest')})
        raw = json.dumps(receipt).encode()
        archive = Path(directory) / 'initialized.zip'
        with zipfile.ZipFile(archive,'w') as zipped:
            zipped.writestr('prod-native-init-receipt.json',raw)
        parent = dict(run_id=123,run_attempt=1,toolkit_commit='a'*40,release_tag='v2026.10.07-r5',artifact_id=456,
            artifact_digest='sha256:'+hashlib.sha256(archive.read_bytes()).hexdigest(),receipt_sha256=hashlib.sha256(raw).hexdigest())
        contract.update(initialization_accepted=True,initialized=parent)
        run = dict(id=123,run_attempt=1,repository={'full_name':CONTROL.BASE.REPOSITORY},event='workflow_dispatch',
            status='completed',conclusion='success',head_sha='a'*40,head_branch=parent['release_tag'],workflow_id=789)
        workflow = dict(id=789,path='.github/workflows/selfhost-orchestrator.yml')
        artifact = dict(id=456,name='prod-native-init-receipt',expired=False,digest=parent['artifact_digest'],
            workflow_run={'id':123,'head_sha':'a'*40},size_in_bytes=archive.stat().st_size)
        return contract,run,workflow,artifact,archive,receipt

    def test_exact_apply_parent_and_original_bytes_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            c,r,w,a,z,_=self.fixture(directory)
            CONTROL.validate_billing(c)
            CONTROL.validate_initialized(c,r,w,a)
            CONTROL.validate_initialized_receipt(c,z)

    def test_pending_failed_rerun_foreign_or_wrong_artifact_refused(self):
        for mutation in ('pending','failed','rerun','foreign','sha','tag','workflow','name','digest','expired'):
            with self.subTest(mutation=mutation),tempfile.TemporaryDirectory() as directory:
                c,r,w,a,_,_=self.fixture(directory)
                if mutation=='pending':c['initialization_accepted']=False
                if mutation=='failed':r['conclusion']='failure'
                if mutation=='rerun':r['run_attempt']=2
                if mutation=='foreign':r['repository']['full_name']='other/repo'
                if mutation=='sha':r['head_sha']='b'*40
                if mutation=='tag':r['head_branch']='main'
                if mutation=='workflow':w['path']='other.yml'
                if mutation=='name':a['name']='prod-native-standby-receipt'
                if mutation=='digest':a['digest']='sha256:'+'c'*64
                if mutation=='expired':a['expired']=True
                with self.assertRaises(ValueError):CONTROL.validate_initialized(c,r,w,a)

    def test_preview_nonempty_writer_active_or_other_schema_receipt_refused(self):
        for key,value in [('stage','native_schema_preview'),('result','eligible'),('schema_initialized',False),
                          ('business_rows',1),('writers_paused',False),('migration_version',2026100701),
                          ('schema_sha256','0'*64),('image_digest','sha256:'+'0'*64),
                          ('database_cutover_approved',True),('business_tables',['users'])]:
            with self.subTest(key=key),tempfile.TemporaryDirectory() as directory:
                c,_,_,_,z,receipt=self.fixture(directory);receipt[key]=value
                raw=json.dumps(receipt).encode()
                with zipfile.ZipFile(z,'w') as zipped:zipped.writestr('prod-native-init-receipt.json',raw)
                c['initialized']['artifact_digest']='sha256:'+hashlib.sha256(z.read_bytes()).hexdigest()
                c['initialized']['receipt_sha256']=hashlib.sha256(raw).hexdigest()
                with self.assertRaises(ValueError):CONTROL.validate_initialized_receipt(c,z)

    def test_original_byte_hash_and_flat_archive_required(self):
        with tempfile.TemporaryDirectory() as directory:
            c,_,_,_,z,_=self.fixture(directory)
            c['initialized']['receipt_sha256']='0'*64
            with self.assertRaises(ValueError):CONTROL.validate_initialized_receipt(c,z)
        with tempfile.TemporaryDirectory() as directory:
            c,_,_,_,z,_=self.fixture(directory)
            with zipfile.ZipFile(z,'a') as zipped:zipped.writestr('untrusted.json','{}')
            c['initialized']['artifact_digest']='sha256:'+hashlib.sha256(z.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):CONTROL.validate_initialized_receipt(c,z)

    def test_manifest_rejects_unbounded_scope_and_versions(self):
        c=json.loads((ROOT/'.github/config/prod-native-billing.json').read_text());CONTROL.validate_billing(c)
        for key,value in [('business_tables',['users']),('migration_file','../../other.sql'),('commit','main'),
                          ('expected_schema_version',0),('target_schema_version',2026100702),('no_business_seeds',False)]:
            d=copy.deepcopy(c);d['billing'][key]=value
            with self.assertRaises(ValueError):CONTROL.validate_billing(d)

    def test_explicit_inputs_and_rerun_protection(self):
        event={'inputs':dict(operation='native-billing-plan',vault_env_path='prod',target_domains='web-saas',
            cloud_provider='gcp-cloud',cloud_account='xworktech',target_domain_base='svc.plus',dns_mode='none',
            runner_type='ubuntu-latest',offline_mode='off')}
        args=('refs/tags/v2026.10.07-r5','a'*40,CONTROL.BASE.REPOSITORY,'1')
        self.assertTrue(CONTROL.validate_inputs(event,*args))
        event['inputs']['operation']='native-billing'
        self.assertFalse(CONTROL.validate_inputs(event,*args))
        with self.assertRaises(ValueError):CONTROL.validate_inputs(event,*args[:-1],'2')
        event['inputs']['deploy_tag']='accounts:latest'
        with self.assertRaises(ValueError):CONTROL.validate_inputs(event,*args)

    def test_pending_configuration_does_not_forge_real_initialization(self):
        c=json.loads((ROOT/'.github/config/prod-native-billing.json').read_text())
        if c['initialization_accepted']:
            self.assertTrue(all(v is not None for v in c['initialized'].values()))
        else:
            self.assertTrue(all(v is None for v in c['initialized'].values()))
        pending=copy.deepcopy(c);pending['initialization_accepted']=False
        with self.assertRaises(ValueError):CONTROL.validate_initialized(pending,{}, {}, {})

    def test_review_and_parents_precede_secrets_cleanup_precedes_evidence(self):
        c=json.loads((ROOT/'.github/config/prod-native-billing.json').read_text())
        workflow=yaml.safe_load((ROOT/'.github/workflows/selfhost-orchestrator.yml').read_text())
        job=workflow['jobs']['native_prod_billing'];self.assertEqual(job['environment'],'prod')
        steps=job['steps'];gate=next(i for i,s in enumerate(steps) if s.get('id')=='native_billing_control')
        vault=next(i for i,s in enumerate(steps) if s.get('id')=='native_vault');self.assertLess(gate,vault)
        remote=[s['uses'] for s in steps if '.github/actions/prod-' in s.get('uses','')]
        self.assertEqual(remote,['ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@'+c['iac_commit'],
            'ai-workspace-infra/playbooks/.github/actions/prod-native-billing-upgrade@'+c['playbooks_commit'],
            'ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@'+c['iac_commit']])
        close=next(i for i,s in enumerate(steps) if s.get('with',{}).get('phase')=='close')
        self.assertIn('always()',steps[close]['if'])
        for i,s in enumerate(steps):
            if s.get('uses','').startswith('actions/upload-artifact@'):
                self.assertGreater(i,close);self.assertNotIn('access',s['with']['path'])
        owner=next(s for s in steps if 'prod-native-billing-upgrade@' in s.get('uses',''))
        self.assertEqual(owner['with']['data_gate_verified'],'${{ steps.native_billing_control.outputs.data_gate_verified }}')
        self.assertEqual(owner['with']['billing_commit'],'${{ steps.native_billing_control.outputs.billing_commit }}')
        for name in ('provision','summary'):
            if name not in workflow['jobs']:continue
            self.assertIn("operation != 'native-billing'",workflow['jobs'][name]['if'])


if __name__=='__main__':unittest.main()
