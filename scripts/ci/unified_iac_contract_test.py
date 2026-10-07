#!/usr/bin/env python3
"""Offline contracts for the delivery DAG and caller handoff (no cloud calls)."""
import ast
import copy
import re
import subprocess
import unittest
from pathlib import Path
import yaml
import workflow_gating_verify as gates

ROOT = Path(__file__).resolve().parents[2]
WF = ROOT / '.github/workflows'
def load(name):
    return yaml.safe_load((WF / name).read_text())


def triggers(workflow):
    # PyYAML 1.1 may parse the unquoted key `on` as boolean True.
    return workflow.get('on', workflow.get(True))

class UnifiedWorkflowContract(unittest.TestCase):
    def test_independent_forward_reverse_dags_and_exact_terminal_gate(self):
        jobs = load('iac-pipeline-multi-cloud-master.yaml')['jobs']
        self.assertEqual(set(jobs), {'prepare','bootstrap','account','resources','destroy-resources','destroy-account','destroy-bootstrap','summary'})
        self.assertIn('bootstrap', jobs['account']['needs'])
        self.assertIn('account', jobs['resources']['needs'])
        self.assertIn('destroy-resources', jobs['destroy-account']['needs'])
        self.assertIn('destroy-account', jobs['destroy-bootstrap']['needs'])
        self.assertTrue(gates.terminal_iac_evidence_gate(jobs['summary'],jobs['summary']['needs']))
        broken = copy.deepcopy(jobs['summary'])
        next(s for s in broken['steps'] if s.get('uses','').endswith('/iac-summary'))['continue-on-error'] = True
        self.assertFalse(gates.terminal_iac_evidence_gate(broken,broken['needs']))
        self.assertFalse(gates.terminal_iac_evidence_gate(jobs['summary'],['prepare']))
        self.assertFalse(gates.terminal_iac_evidence_gate({'steps':[{'run':'echo success'}]},jobs['summary']['needs']))

    def test_three_stage_module_and_static_matrix_have_one_execution_owner(self):
        stages = load('iac-pipeline-multi-cloud-stages.yaml')['jobs']
        self.assertEqual(set(stages), {'bootstrap','account','resources'})
        for name, job in stages.items():
            self.assertNotIn('needs',job)
            self.assertEqual(job['concurrency']['group'],'iac-state-${{ inputs.lock_key }}')
            self.assertFalse(job['concurrency']['cancel-in-progress'])
            self.assertTrue(any(s.get('uses') == './iac_modules/.github/actions/iac-'+name for s in job['steps']))
        jobs = load('iac-self-check-matrix.yml')['jobs']
        self.assertEqual(set(jobs),{'prepare','self-check','execute-iac','summary'})
        self.assertEqual(jobs['execute-iac']['uses'],'./.github/workflows/iac-pipeline-multi-cloud-master.yaml')
        self.assertFalse(any('iac-self-check-matrix' in j.get('uses','') for j in load('iac-pipeline-multi-cloud-master.yaml')['jobs'].values()))
        self.assertTrue(gates.terminal_iac_evidence_gate(jobs['summary'],jobs['summary']['needs']))

    def test_static_events_are_centralized_and_compatibility_entries_remain_callable(self):
        matrix_events = triggers(load('iac-self-check-matrix.yml'))
        self.assertEqual(set(matrix_events), {'workflow_dispatch','workflow_call','pull_request','push'})
        self.assertEqual(set(matrix_events['push']['branches']), {'main','release/**'})
        for event in ('push','pull_request'):
            paths = set(matrix_events[event]['paths'])
            self.assertIn('.github/workflows/iac-*', paths)
            self.assertIn('terraform-hcl-standard/**', paths)

        wrappers = (
            'iac-pipeline-multi-cloud-landingzone-baseline.yaml',
            'iac-pipeline-multi-cloud-account-matrix.yaml',
            'iac-pipeline-multi-cloud-resources-matrix.yaml',
        )
        for name in wrappers:
            workflow = load(name)
            self.assertEqual(set(triggers(workflow)), {'workflow_dispatch','workflow_call'}, name)
            self.assertEqual(set(workflow['jobs']), {'resolve','pipeline'}, name)

    def test_retired_toolkit_copies_are_absent_and_aws_recovery_waits_for_evidence(self):
        retired = (
            '.github/actions/terraform-command/action.yml',
            '.github/actions/setup-iac-env/action.yml',
            '.github/scripts/platform-ops/observe/platform-ops_iac-self-check.py',
            '.github/scripts/lib/cmdb-ssh-login.sh',
        )
        for relative in retired:
            self.assertFalse((ROOT / relative).exists(), relative)
        for relative in (
            'scripts/cloud/bootstrap/aws/reconcile_github_oidc_trust.sh',
            'scripts/cloud/bootstrap/aws/adopt_github_oidc_terraform_state.sh',
        ):
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_orchestrators_preserve_inputs_and_gate_exact_receipt(self):
        for name, gate in [('selfhost-orchestrator.yml','provision'),('serverless-orchestrator.yml','iac-verified')]:
            workflow = load(name)
            trigger = workflow.get('on',workflow.get(True))
            self.assertLessEqual(len(trigger['workflow_dispatch']['inputs']),25)
            jobs = workflow['jobs']
            self.assertEqual(jobs['iac']['uses'],'./.github/workflows/iac-pipeline-multi-cloud-master.yaml')
            self.assertEqual(jobs['iac']['with']['stage_scope'],'resources')
            self.assertTrue(any(s.get('uses')=='./iac_modules/.github/actions/iac-receipt-verify' for s in jobs[gate]['steps']))
        options = load('serverless-orchestrator.yml').get('on',load('serverless-orchestrator.yml').get(True))['workflow_dispatch']['inputs']['cloud_provider']['options']
        self.assertIn('ucloud',options)
        steps = load('selfhost-orchestrator.yml')['jobs']['provision']['steps']
        vault = next(i for i,s in enumerate(steps) if s.get('uses')=='hashicorp/vault-action@v4')
        init = next(i for i,s in enumerate(steps) if s.get('name')=='Initialize Databases Credentials')
        self.assertLess(vault,init)

    def test_exact_artifact_id_download_uses_expected_flat_directory(self):
        # download-artifact ID mode creates a name subdirectory unless merging
        # is explicit, even for one ID. Consumers read report/summary at root.
        for name in ('iac-self-check-matrix.yml','selfhost-orchestrator.yml','serverless-orchestrator.yml'):
            for job in load(name)['jobs'].values():
                for step in job.get('steps',[]):
                    if 'artifact-ids' in step.get('with',{}):
                        self.assertIs(step['with'].get('merge-multiple'),True,name)
                        self.assertNotIn(',',step['with']['artifact-ids'])

    def test_generated_shell_and_python_parse(self):
        names = ['iac-pipeline-multi-cloud-master.yaml','iac-pipeline-multi-cloud-stages.yaml','iac-self-check-matrix.yml','gcp-iac-pipeline.yml','gcp-oidc-bootstrap.yml','ucloud-iac.yml','aws-oidc-bootstrap.yml','akamai-cloud-iac.yml']
        for name in names:
            for job in load(name)['jobs'].values():
                for step in job.get('steps',[]):
                    if 'run' not in step:continue
                    source = re.sub(r'\$\{\{.*?\}\}', 'VALUE', step['run'],flags=re.S)
                    result = subprocess.run(['bash','-n'],input=source,text=True,capture_output=True)
                    self.assertEqual(result.returncode,0,name+': '+result.stderr)
                    for code in re.findall(r"python3 - <<'PYCODE'\n(.*?)\nPYCODE",source,re.S):
                        ast.parse(code,filename=name)

if __name__ == '__main__':unittest.main()
