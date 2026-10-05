#!/usr/bin/env python3
"""Offline control-plane contracts: no credentials, database or provider access."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[3]


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / '.github/scripts/environment-upgrade' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow(name):
    return yaml.load((ROOT / '.github/workflows' / name).read_text(), Loader=yaml.BaseLoader)


class DataControlPlaneTests(unittest.TestCase):
    def guard(self, mode, config=None, environment='uat'):
        env = dict(os.environ, OPERATION_MODE=mode, DEPLOY_ENV=environment,
                   DATA_CONFIG_JSON=json.dumps(config or {}))
        # No outbound GitHub call on UAT or a rejected UAT-only PROD operation.
        env.pop('GITHUB_OUTPUT', None)
        return subprocess.run(['python3', str(ROOT / '.github/scripts/environment-upgrade/validate_operation.py')],
                              env=env, capture_output=True, text=True)

    def test_legacy_import_opt_in_and_direction(self):
        self.assertNotEqual(self.guard('legacy_import').returncode, 0)
        self.assertEqual(self.guard('legacy_import', {'confirm_legacy_import': True}).returncode, 0)
        self.assertNotEqual(self.guard('legacy_import', {'confirm_legacy_import': True}, 'prod').returncode, 0)
        self.assertNotEqual(self.guard('legacy_import', {'confirm_legacy_import': True,
                            'supabase_target_existing_strategy': 'replace_public'}).returncode, 0)

    def test_sensitive_or_executable_inputs_rejected(self):
        for config in ({'password': 'do-not-leak'}, {'dsn': 'postgresql://do-not-leak'}, {'command': 'do-not-leak'},
                       {'nested': {'secret_key': 'do-not-leak'}}, {'target_host': 'postgres://do-not-leak'}):
            result = self.guard('probe', config)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('do-not-leak', result.stdout + result.stderr)

    def test_unsafe_modes_and_unknown_environment(self):
        for mode in ('legacy_import', 'akamai_preflight', 'rehearsal', 'baseline', 'migrate', 'selfhost_init'):
            self.assertNotEqual(self.guard(mode, environment='prod').returncode, 0)
        self.assertNotEqual(self.guard('probe', environment='sit').returncode, 0)
        self.assertNotEqual(self.guard('unknown').returncode, 0)
        self.assertNotEqual(self.guard('rollback', {'rollback_mode': 'hard'}).returncode, 0)
        self.assertNotEqual(self.guard('rollback').returncode, 0)  # no fabricated adapter

    def test_rehearsal_rerun_is_rejected_before_credentials(self):
        with patch.dict(os.environ, {'GITHUB_RUN_ATTEMPT': '2'}):
            result = self.guard('rehearsal')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dispatch a new complete run', result.stderr)

    def test_akamai_account_is_explicit(self):
        self.assertNotEqual(self.guard('akamai_preflight').returncode, 0)
        self.assertEqual(self.guard('akamai_preflight', {'account': 'reviewed-account'}).returncode, 0)
        self.assertNotEqual(self.guard('akamai_preflight', {'account': '../escape'}).returncode, 0)

    def test_selfhost_roles_cannot_bypass_release_or_prod_gates(self):
        config = {'execution_path': 'selfhost_roles'}
        for mode in ('preflight', 'backup'):
            self.assertEqual(self.guard(mode, config).returncode, 0)
        for mode in ('migrate', 'probe', 'upgrade', 'rollback', 'rehearsal'):
            self.assertNotEqual(self.guard(mode, config).returncode, 0)
        self.assertNotEqual(self.guard('preflight', config, 'prod').returncode, 0)
        self.assertNotEqual(self.guard('preflight', {'execution_path': 'unknown'}).returncode, 0)

    def test_single_entry_and_fixed_execution_owners(self):
        for name in ('data-migration.yaml', 'migration.yaml', 'rollback-orchestrator.yml',
                     'akamai-uat-migration-preflight.yml', 'environment-application-rollback.yml', 'environment-upgrade.yml'):
            self.assertFalse((ROOT / '.github/workflows' / name).exists(), name)
        entry = workflow('environment-data-operations.yml')
        self.assertIn('workflow_dispatch', entry['on'])
        self.assertIn('workflow_call', entry['on'])
        self.assertEqual(entry['concurrency']['group'], 'environment-data-operations-${{ inputs.environment }}')
        self.assertEqual(entry['concurrency']['cancel-in-progress'], 'false')
        self.assertEqual(entry['jobs']['request_gate']['environment'], '${{ inputs.environment }}')
        for job, owner in (('legacy_import', 'playbooks'), ('serverless_database', 'playbooks'),
                           ('selfhost_database', 'playbooks'), ('selfhost_components', 'playbooks'),
                           ('akamai_preflight', 'iac_modules')):
            uses = entry['jobs'][job]['uses']
            self.assertRegex(uses, rf'^ai-workspace-infra/{owner}/.github/workflows/[^@]+@[0-9a-f]{{40}}$')
        self.assertLessEqual(len(entry['on']['workflow_dispatch']['inputs']), 25)

    def test_parent_orchestrators_dispatch_and_wait(self):
        for name in ('hybrid-orchestrator.yml', 'selfhost-orchestrator.yml', 'serverless-orchestrator.yml'):
            value = workflow(name)
            text = (ROOT / '.github/workflows' / name).read_text()
            self.assertIn('environment-upgrade/dispatch.py', text)
            self.assertEqual(value['permissions']['actions'], 'write')
            for forbidden in ('data-migration.yaml', 'apply_accounts_incremental_schema.sh',
                              'create_release_checkpoint.sh', 'restore_release_checkpoint.sh',
                              'initialize-web-saas-databases.sh'):
                self.assertNotIn(forbidden, text)
        serverless = workflow('serverless-orchestrator.yml')['jobs']
        for job in ('supabase', 'uat_accounts_schema_probe', 'uat_accounts_baseline', 'uat_accounts_schema_migration'):
            self.assertIn('environment-upgrade/dispatch.py', json.dumps(serverless[job]))

    def test_vault_claims_keep_caller_repository_and_exact_owner_sha(self):
        for env in ('uat', 'prod', 'sit', 'dev'):
            role = json.loads((ROOT / 'scripts/vault/roles' / f'github-actions-platform-ops-toolkit-{env}.json').read_text())
            self.assertEqual(role['bound_claims']['repository'], 'ai-workspace-infra/platform-ops-toolkit')
            refs = role['bound_claims']['job_workflow_ref']
            self.assertFalse(any('data-migration.yaml' in ref for ref in refs))
            if env in ('uat', 'prod'):
                owners = [ref for ref in refs if '/playbooks/' in ref]
                self.assertTrue(owners)
                self.assertTrue(all(re.search(r'@[0-9a-f]{40}$', ref) for ref in owners))
                self.assertEqual(any('uat-data-import.yaml' in ref for ref in owners), env == 'uat')

    def test_dispatch_does_not_accept_failed_child(self):
        dispatch = load_module('dispatch')
        env = {'DATA_ENVIRONMENT': 'uat', 'DATA_OPERATION': 'probe', 'DATA_CONFIG_JSON': '{}'}
        run = {'id': 42, 'display_title': 'data:data-correlation / probe / uat',
               'html_url': 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/42',
               'status': 'completed', 'conclusion': 'failure'}
        with patch.dict(os.environ, env, clear=True), patch.object(dispatch.uuid, 'uuid4') as uuid, \
             patch.object(dispatch, 'gh', side_effect=[{}, {'workflow_runs': [run]}]):
            uuid.return_value.hex = 'correlation'
            with self.assertRaisesRegex(SystemExit, 'failed'):
                dispatch.main()

    def test_prod_missing_reviewers_blocks_before_credentials(self):
        gate = load_module('validate_operation')
        env = {'OPERATION_MODE': 'probe', 'DEPLOY_ENV': 'prod', 'DATA_CONFIG_JSON': '{}',
               'GITHUB_REPOSITORY': 'ai-workspace-infra/platform-ops-toolkit'}
        with patch.dict(os.environ, env, clear=True), patch.object(gate.subprocess, 'run') as run:
            run.return_value.stdout = '{"protection_rules":[]}'
            with self.assertRaisesRegex(SystemExit, 'reviewers'):
                gate.main()


if __name__ == '__main__':
    unittest.main(verbosity=2)
