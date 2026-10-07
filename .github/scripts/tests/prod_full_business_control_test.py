"""Immutable parents and workflow shape only; never reads a managed database."""
import hashlib
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
import yaml

ROOT = Path(__file__).resolve().parents[3]
loader = importlib.util.spec_from_file_location('full_business_control', ROOT / '.github/scripts/prod-selfhost/full_business_control.py')
CONTROL = importlib.util.module_from_spec(loader)
loader.loader.exec_module(CONTROL)


class FullBusinessControlTests(unittest.TestCase):
    def contract(self):
        c = json.loads((ROOT / '.github/config/prod-full-business.json').read_text())
        c['source'].update(ready=True, identity_sha256='1' * 64)
        return c

    def fixture(self, directory, kind):
        c = self.contract()
        initial, billing, transfer = (c[k] for k in ('initialization', 'billing', 'transfer'))
        receipt = dict(environment='prod', host='web-saas-prod', database='account', migration_version=2026100701,
            business_tables=transfer['business_tables'], writers_paused=True, independent_disk_verified=True,
            database_cutover_approved=False)
        if kind == 'billing':
            receipt.update(stage='native_billing_schema_upgraded', result='upgraded', target_version=2026100701,
                business_rows=0, accounts_commit=initial['accounts_commit'], image_digest=initial['image_digest'],
                billing_commit=billing['commit'], migration_sha256=billing['migration_sha256'], schema_changed=True)
            key, flag, name = 'upgraded', 'billing_accepted', 'prod-native-billing-receipt'
        else:
            receipt.update(stage='full_business_baseline_copied', result='copied', format=1,
                accounts_commit=transfer['accounts_commit'], image_digest=transfer['image_digest'],
                schema_sha256=transfer['schema_sha256'], billing_schema_sha256=transfer['billing_schema_sha256'],
                batch_size=1000, source_identity_sha256=c['source']['identity_sha256'], source_snapshot_sha256='2' * 64,
                source_catalog_sha256='3' * 64, source_read_only=True, full_business_equal=True, target_writes=True,
                source_writers_paused=False, final_catchup_complete=False, source_table_count=44, user_count=24,
                snapshot_started_at='2026-10-07T00:00:00Z', completed_at='2026-10-07T00:01:00Z',
                tables={t: {'rows': 24 if t == 'users' else 0, 'sha256': '4' * 64} for t in transfer['business_tables']})
            key, flag, name = 'copied', 'copy_accepted', 'prod-full-business-receipt'
        archive = Path(directory) / (kind + '.zip')
        raw = json.dumps(receipt).encode()
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr(name + '.json', raw)
        parent = dict(run_id=123, run_attempt=1, toolkit_commit='a'*40, release_tag='v2026.10.07-r5', artifact_id=456,
            artifact_digest='sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest(), receipt_sha256=hashlib.sha256(raw).hexdigest())
        c.update({flag: True, key: parent})
        run = dict(id=123, run_attempt=1, repository={'full_name': CONTROL.BASE.REPOSITORY}, event='workflow_dispatch',
            status='completed', conclusion='success', head_sha='a'*40, head_branch=parent['release_tag'], workflow_id=789)
        workflow = dict(id=789, path='.github/workflows/selfhost-orchestrator.yml')
        artifact = dict(id=456, name=name, expired=False, digest=parent['artifact_digest'],
            workflow_run={'id': 123, 'head_sha': 'a'*40}, size_in_bytes=archive.stat().st_size)
        return c, run, workflow, artifact, archive, receipt, key, name

    def test_actual_billing_and_complete_copy_original_bytes(self):
        for kind in ('billing', 'copy'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                c, r, w, a, z, *_ = self.fixture(directory, kind)
                CONTROL.validate_contract(c)
                CONTROL.validate_parent(c, kind, r, w, a)
                CONTROL.validate_parent_receipt(c, kind, z)

    def test_pending_configuration_is_honest_and_cannot_run(self):
        c = json.loads((ROOT / '.github/config/prod-full-business.json').read_text())
        CONTROL.validate_contract(c, require_source=False)
        pending=copy.deepcopy(c); pending['source'].update(ready=False,identity_sha256=None)
        CONTROL.validate_contract(pending)
        for flag, key, kind in [('initialization_accepted','initialized',None), ('billing_accepted','upgraded','billing'), ('copy_accepted','copied','copy')]:
            self.assertIsInstance(c[flag],bool)
            if c[flag]: self.assertTrue(all(v is not None for v in c[key].values()))
            else: self.assertTrue(all(v is None for v in c[key].values()))
            if kind:
                pending=copy.deepcopy(c); pending[flag]=False
                with self.assertRaises(ValueError): CONTROL.parent_details(pending, kind)

    def test_scope_source_image_and_version_tampering_refused(self):
        for section, key, value in [('source','role','postgres'), ('source','tls_required',False),
            ('source','direction','uat-to-prod'), ('source','identity_sha256',''), ('transfer','batch_size',10000),
            ('transfer','business_tables',['users']), ('transfer','migration_version',2026100702),
            ('transfer','database_cutover_approved',True), ('transfer','image','accounts:latest'),
            ('transfer','schema_sha256','0'*64), ('billing','migration_sha256','0'*64)]:
            with self.subTest(section=section, key=key):
                c=self.contract(); c[section][key]=value
                with self.assertRaises(ValueError): CONTROL.validate_contract(c)

    def test_foreign_failed_rerun_wrong_name_or_digest_parent_refused(self):
        for kind in ('billing','copy'):
            for mutation in ('failed','rerun','foreign','sha','tag','workflow','name','digest','expired','bool_id'):
                with self.subTest(kind=kind, mutation=mutation), tempfile.TemporaryDirectory() as directory:
                    c,r,w,a,_,_,key,_=self.fixture(directory,kind)
                    if mutation=='failed': r['conclusion']='failure'
                    if mutation=='rerun': r['run_attempt']=2
                    if mutation=='foreign': r['repository']['full_name']='other/repo'
                    if mutation=='sha': r['head_sha']='b'*40
                    if mutation=='tag': r['head_branch']='main'
                    if mutation=='workflow': w['path']='other.yml'
                    if mutation=='name': a['name']='prod-native-standby-receipt'
                    if mutation=='digest': a['digest']='sha256:'+'0'*64
                    if mutation=='expired': a['expired']=True
                    if mutation=='bool_id': c[key]['run_id']=True
                    with self.assertRaises(ValueError): CONTROL.validate_parent(c,kind,r,w,a)

    def test_preview_nonempty_billing_or_partial_copy_is_not_parent_acceptance(self):
        cases={'billing':[('stage','native_billing_schema_preview'), ('result','eligible'), ('business_rows',1),
            ('target_version',2026100702), ('billing_commit','0'*40)],
            'copy':[('stage','full_business_compared'), ('result','equal'), ('full_business_equal',False),
            ('target_writes',False), ('source_read_only',False), ('user_count',23), ('source_identity_sha256','0'*64),
            ('tables',{'users':{'rows':24,'sha256':'4'*64}}), ('completed_at','2026-10-07T01:00:00Z'),
            ('source_writers_paused',True), ('final_catchup_complete',True)]}
        common=[('writers_paused',False), ('independent_disk_verified',False), ('migration_version',2026100601),
            ('database_cutover_approved',True), ('business_tables',['users']), ('image_digest','sha256:'+'0'*64)]
        for kind in ('billing','copy'):
            for field,value in cases[kind]+common:
                with self.subTest(kind=kind, field=field), tempfile.TemporaryDirectory() as directory:
                    c,_,_,_,z,receipt,key,name=self.fixture(directory,kind)
                    receipt[field]=value; raw=json.dumps(receipt).encode()
                    with zipfile.ZipFile(z,'w') as zipped: zipped.writestr(name+'.json',raw)
                    c[key]['artifact_digest']='sha256:'+hashlib.sha256(z.read_bytes()).hexdigest()
                    c[key]['receipt_sha256']=hashlib.sha256(raw).hexdigest()
                    with self.assertRaises(ValueError): CONTROL.validate_parent_receipt(c,kind,z)

    def test_archive_original_hash_duplicates_path_and_symlinks_refused(self):
        for mutation in ('raw_hash','extra','duplicate','nested','symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                c,_,_,_,z,receipt,key,name=self.fixture(directory,'copy')
                if mutation=='raw_hash': c[key]['receipt_sha256']='0'*64
                elif mutation in ('extra','duplicate'):
                    with zipfile.ZipFile(z,'a') as zipped: zipped.writestr(name+'.json' if mutation=='duplicate' else 'untrusted.json','{}')
                else:
                    with zipfile.ZipFile(z,'w') as zipped:
                        entry=zipfile.ZipInfo('../'+name+'.json' if mutation=='nested' else name+'.json')
                        if mutation=='symlink': entry.external_attr=0o120777 << 16
                        zipped.writestr(entry,json.dumps(receipt))
                c[key]['artifact_digest']='sha256:'+hashlib.sha256(z.read_bytes()).hexdigest()
                with self.assertRaises(ValueError): CONTROL.validate_parent_receipt(c,'copy',z)

    def test_explicit_modes_immutable_tag_and_no_reruns(self):
        event={'inputs':dict(vault_env_path='prod',target_domains='web-saas',cloud_provider='gcp-cloud',
            cloud_account='xworktech',target_domain_base='svc.plus',dns_mode='none',runner_type='ubuntu-latest',offline_mode='off')}
        args=('refs/tags/v2026.10.07-r5','a'*40,CONTROL.BASE.REPOSITORY,'1')
        for operation,mode in CONTROL.MODES.items():
            event['inputs']['operation']=operation; self.assertEqual(CONTROL.validate_inputs(event,*args),mode)
            with self.assertRaises(ValueError): CONTROL.validate_inputs(event,*args[:-1],'2')
            with self.assertRaises(ValueError): CONTROL.validate_inputs(event,'refs/heads/main',*args[1:])
        event['inputs']['operation']='native-business-copy'; event['inputs']['vault_env_path']='uat'
        with self.assertRaises(ValueError): CONTROL.validate_inputs(event,*args)

    def test_gate_secrets_fixed_owners_cleanup_then_publication(self):
        c=json.loads((ROOT/'.github/config/prod-full-business.json').read_text())
        w=yaml.safe_load((ROOT/'.github/workflows/selfhost-orchestrator.yml').read_text())
        job=w['jobs']['native_prod_business']; self.assertEqual(job['environment'],'prod'); steps=job['steps']
        gate=next(i for i,s in enumerate(steps) if s.get('id')=='full_business_control')
        vault=next(i for i,s in enumerate(steps) if s.get('id')=='native_vault'); self.assertLess(gate,vault)
        self.assertLess(gate,next(i for i,s in enumerate(steps) if s.get('id')=='native_access'))
        secrets=steps[vault]['with']['secrets']; self.assertIn('kv/data/prod/database-upgrade PROD_SUPABASE_READONLY_DSN',secrets)
        self.assertIs(steps[vault]['with']['exportEnv'],False)
        self.assertNotIn('kv/data/uat/',secrets)
        remote=[s['uses'] for s in steps if '.github/actions/prod-' in s.get('uses','')]
        self.assertEqual(remote,['ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@'+c['iac_commit'],
            'ai-workspace-infra/playbooks/.github/actions/prod-full-business@'+c['playbooks_commit'],
            'ai-workspace-infra/iac_modules/.github/actions/prod-selfhost-access@'+c['iac_commit']])
        owner=next(s for s in steps if 'prod-full-business@' in s.get('uses',''))
        for key in ('mode','data_gate_verified'):
            self.assertEqual(owner['with'][key],'${{ steps.full_business_control.outputs.'+key+' }}')
        self.assertEqual(owner['with']['source_dsn'],'${{ steps.native_vault.outputs.NATIVE_SOURCE_DSN }}')
        close=next(i for i,s in enumerate(steps) if s.get('with',{}).get('phase')=='close'); self.assertIn('always()',steps[close]['if'])
        for i,s in enumerate(steps):
            if s.get('uses','').startswith('actions/upload-artifact@'):
                self.assertGreater(i,close); self.assertNotIn('access',s['with']['path']); self.assertNotIn('spec',s['with']['path'])
        for name in ('provision','deployment_summary'):
            for operation in CONTROL.MODES: self.assertIn("operation != '"+operation+"'",w['jobs'][name]['if'])


if __name__=='__main__': unittest.main()
