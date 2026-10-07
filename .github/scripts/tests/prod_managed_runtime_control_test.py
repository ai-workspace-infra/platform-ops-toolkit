"""Isolated image review contracts; data approval remains independent."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[3]
loader=importlib.util.spec_from_file_location('managed_runtime_control',ROOT/'.github/scripts/prod-selfhost/managed_runtime_control.py')
CONTROL=importlib.util.module_from_spec(loader);loader.loader.exec_module(CONTROL)


def spec():
    return dict(schema=1,environment='prod',host='web-saas-prod',services={
        name:dict(commit=sha*40,image='ghcr.io/ai-workspace-services/'+repo+':sha-'+sha*40,image_digest='sha256:'+'c'*64)
        for name,repo,sha in [('accounts','accounts','a'),('billing','billing-service','b')]})


def review():
    environment=dict(name='prod',id=8,protection_rules=[dict(type='required_reviewers',prevent_self_review=False,
        reviewers=[dict(type='User',reviewer=dict(login='starter'))])])
    run=dict(id=999,run_attempt=1,event='workflow_dispatch',head_sha='d'*40,head_branch='v2026.10.07-r5',
             repository=dict(full_name=CONTROL.BASE.REPOSITORY),actor=dict(login='starter'),triggering_actor=dict(login='starter'))
    reviews=[dict(state='approved',user=dict(login='starter'),environments=[dict(id=8,name='prod')])]
    return environment,run,reviews


class RuntimeControlTests(unittest.TestCase):
    def test_no_business_or_database_override_in_manifest(self):
        CONTROL.validate_spec(spec())
        cases=[]
        for key,value in [('schema',True),('environment','uat'),('host','other'),('database_url','forbidden')]:
            v=spec();v[key]=value;cases.append(v)
        v=spec();v['services'].pop('billing');cases.append(v)
        for key,value in [('commit','main'),('image','mutable'),('image_digest','pending'),('role','primary')]:
            v=spec();v['services']['accounts'][key]=value;cases.append(v)
        for v in cases:
            with self.assertRaises(ValueError):CONTROL.validate_spec(v)

    def test_isolated_image_review_never_satisfies_independent_data_gate(self):
        e,r,v=review()
        CONTROL.validate_review(e,r,v,'999','d'*40,'refs/tags/v2026.10.07-r5')
        with self.assertRaises(ValueError):CONTROL.INIT.validate_data_review(e,r,v,'999','d'*40,'refs/tags/v2026.10.07-r5')
        e['protection_rules'][0]['prevent_self_review']=True
        with self.assertRaises(ValueError):CONTROL.validate_review(e,r,v,'999','d'*40,'refs/tags/v2026.10.07-r5')

    def test_missing_foreign_unconfigured_or_rerun_review_is_refused(self):
        for change in ('no-review','wrong-reviewer','wrong-env','rerun','branch','sha','other-repo'):
            e,r,v=review()
            if change=='no-review':v=[]
            if change=='wrong-reviewer':v[0]['user']['login']='other'
            if change=='wrong-env':v[0]['environments'][0]['id']=9
            if change=='rerun':r['run_attempt']=2
            if change=='branch':r['head_branch']='main'
            if change=='sha':r['head_sha']='a'*40
            if change=='other-repo':r['repository']['full_name']='other/repo'
            with self.assertRaises(ValueError):CONTROL.validate_review(e,r,v,'999','d'*40,'refs/tags/v2026.10.07-r5')

    def test_immutable_dispatch_and_canonical_no_dns_target(self):
        event=dict(inputs=dict(operation='native-runtime-plan',vault_env_path='prod',target_domains='web-saas',
             cloud_provider='gcp-cloud',cloud_account='xworktech',target_domain_base='svc.plus',dns_mode='none',
             runner_type='ubuntu-latest',offline_mode='off',deploy_tag='',source_ref=''))
        args=('refs/tags/v2026.10.07-r5','d'*40,CONTROL.BASE.REPOSITORY,'1')
        self.assertTrue(CONTROL.validate_inputs(event,*args))
        event['inputs']['operation']='native-runtime-qualify'
        self.assertFalse(CONTROL.validate_inputs(event,*args))
        for key,value in [('operation','deploy'),('dns_mode','cloudflare'),('vault_env_path','uat'),
                          ('deploy_tag','latest'),('source_ref','main'),('target_domains','all')]:
            v=copy.deepcopy(event);v['inputs'][key]=value
            with self.assertRaises(ValueError):CONTROL.validate_inputs(v,*args)
        with self.assertRaises(ValueError):CONTROL.validate_inputs(event,*args[:-1],'2')

    def test_registry_only_job_cleanup_before_evidence_and_separate_data_gates(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/selfhost-orchestrator.yml').read_text())
        inputs=workflow.get('on',workflow.get(True))['workflow_dispatch']['inputs']
        self.assertEqual(len(inputs),25)
        self.assertEqual(inputs['operation']['default'],'plan')
        self.assertIn('native-runtime-qualify',inputs['operation']['options'])
        job=workflow['jobs']['native_prod_runtime']
        self.assertEqual(job['environment'],'prod')
        self.assertIn('native-runtime-plan',job['if'])
        self.assertNotIn('NATIVE_POSTGRES_PASSWORD',str(job))
        self.assertNotIn('SUPABASE_READONLY',str(job))
        steps=job['steps']
        control=next(i for i,s in enumerate(steps) if s.get('id')=='managed_runtime_control')
        vault=next(i for i,s in enumerate(steps) if s.get('id')=='native_vault')
        cleanup=next(i for i,s in enumerate(steps) if s.get('with',{}).get('phase')=='close')
        upload=next(i for i,s in enumerate(steps) if s.get('uses','').startswith('actions/upload-artifact'))
        self.assertLess(control,vault);self.assertLess(cleanup,upload)
        self.assertIs(steps[vault]['with']['exportToken'],False)
        self.assertIs(steps[vault]['with']['exportEnv'],False)
        self.assertNotIn('databases',steps[vault]['with']['secrets'])
        for key in ('native_prod_init','native_prod_billing','native_prod_business'):
            self.assertNotIn('native-runtime-',workflow['jobs'][key]['if'])
        for key in ('route','deploy_non_iac'):
            if key in workflow['jobs']:
                self.assertIn("operation != 'native-runtime-qualify'",workflow['jobs'][key]['if'])

    def test_caller_config_fixed_owner_and_data_acceptance_unchanged(self):
        contract=json.loads((ROOT/'.github/config/prod-managed-runtime.json').read_text())
        self.assertEqual(contract['scope'],'prod-managed-runtime-qualification-only')
        CONTROL.validate_spec(contract['runtime'])
        workflow=(ROOT/'.github/workflows/selfhost-orchestrator.yml').read_text()
        self.assertIn('ai-workspace-infra/playbooks/.github/actions/prod-managed-runtime@'+contract['playbooks_commit'],workflow)
        source=json.loads((ROOT/'.github/config/prod-full-business.json').read_text())
        # A legitimate future data acceptance must remain possible through its
        # own evidence gate. This image contract cannot produce such flags.
        self.assertFalse(set(contract) & {'source','initialization_accepted','billing_accepted',
                                         'copy_accepted','database_cutover_approved'})
        self.assertEqual(contract['resource'],source['resource'])
        self.assertEqual(contract['standby'],source['standby'])


if __name__=='__main__':unittest.main()
