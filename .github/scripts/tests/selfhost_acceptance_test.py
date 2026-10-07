import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[3]

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value

ADAPTER=module('core_adapter','.github/scripts/environment-upgrade/dispatch_core_users.py')
CONTROL=module('core_control','.github/scripts/prod-selfhost/full_business_control.py')


class AcceptanceTests(unittest.TestCase):
    def test_core_compare_defaults_without_copy_or_dns(self):
        inputs=ADAPTER.dispatch_inputs('v2026.10.07-r26')
        self.assertEqual(inputs['operation'],'native-core-users-compare')
        self.assertEqual(inputs['dns_mode'],'none')
        self.assertEqual(ADAPTER.dispatch_inputs('v2026.10.07-r26','copy')['operation'],'native-core-users')
        self.assertEqual(ADAPTER.dispatch_inputs('v2026.10.07-r26','availability')['operation'],'native-availability')

    def test_availability_input_is_prod_readonly_without_source_credentials(self):
        env=dict(os.environ,OPERATION_MODE='selfhost_availability',DEPLOY_ENV='prod',
            RELEASE_TAG='v2026.10.07-r26',GITHUB_REF='refs/tags/v2026.10.07-r26',DATA_CONFIG_JSON='{}')
        result=subprocess.run(['python3',str(ROOT/'.github/scripts/environment-upgrade/validate_operation.py')],env=env,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        env['DATA_CONFIG_JSON']='{"action":"copy"}'
        self.assertNotEqual(subprocess.run(['python3',str(ROOT/'.github/scripts/environment-upgrade/validate_operation.py')],env=env,capture_output=True).returncode,0)

    def test_compare_without_copy_acceptance_only_checks_resource_provenance(self):
        contract=json.loads((ROOT/'.github/config/prod-full-business.json').read_text())
        contract.update(initialization_accepted=False,billing_accepted=False,copy_accepted=False)
        event={'inputs':{'operation':'native-core-users-compare'}}
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'contract.json').write_text(json.dumps(contract));(root/'event.json').write_text(json.dumps(event))
            env=dict(GITHUB_EVENT_NAME='workflow_dispatch',GITHUB_EVENT_PATH=str(root/'event.json'),GITHUB_REF='refs/tags/v2026.10.07-r26',GITHUB_SHA='a'*40,GITHUB_REPOSITORY=CONTROL.BASE.REPOSITORY,GITHUB_RUN_ATTEMPT='1',GITHUB_RUN_ID='42',RUNNER_TEMP=d)
            with patch.dict(os.environ,env),patch('sys.argv',['control','--contract',str(root/'contract.json'),'--destination',str(root/'cmdb')]), \
                 patch.object(CONTROL,'validate_inputs',return_value='core_users_compare'), \
                 patch.object(CONTROL.INIT,'validate_data_review'),patch.object(CONTROL.BASE,'get_json',return_value={'workflow_id':1}), \
                 patch.object(CONTROL.BASE,'validate_provenance') as provenance, \
                 patch.object(CONTROL.INIT,'download'),patch.object(CONTROL.BASE,'stage_archive'), \
                 patch.object(CONTROL,'parent_details',side_effect=AssertionError('copy/schema receipt must not be required')):
                CONTROL.main()
                provenance.assert_called_once()

    def test_failed_child_and_four_field_mismatch_are_refused(self):
        proof=dict(count=1,email_sha256='1'*64,password_hash_sha256='2'*64,email_proxy_sha256='3'*64)
        receipt=dict(environment='prod',scope='core_users',stage='core_users_compared',host='web-saas-prod',database='account',source_read_only=True,target_writes=False,core_users={'source':proof,'target':proof.copy()},user_count=1,tables={})
        run=dict(status='completed',conclusion='success')
        ADAPTER.validate_core_receipt(receipt,run,compare=True)
        for field,value in (('count',2),('email_sha256','4'*64),('password_hash_sha256','4'*64),('email_proxy_sha256','4'*64)):
            changed=json.loads(json.dumps(receipt));changed['core_users']['target'][field]=value
            with self.assertRaises(SystemExit): ADAPTER.validate_core_receipt(changed,run,compare=True)
        with self.assertRaises(SystemExit): ADAPTER.validate_core_receipt(receipt,{'status':'completed','conclusion':'failure'},compare=True)

    def test_prod_availability_is_independent_of_uat_baseline_and_dns(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/selfhost-orchestrator.yml').read_text())
        health=workflow['jobs']['prod_availability']
        self.assertNotIn('capture_web_saas_baseline',health['needs'])
        self.assertNotIn('switch_dns',health['needs'])
        self.assertIn('prod_availability',workflow['jobs']['deployment_summary']['needs'])
        self.assertIn('native-core-users-compare',workflow['jobs']['native_prod_business']['if'])
        text=json.dumps(health)
        self.assertNotIn('native-init',text)
        self.assertIn('prod-availability@',text)
        self.assertIn('phase',text)


if __name__=='__main__':unittest.main()
