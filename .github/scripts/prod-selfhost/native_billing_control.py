#!/usr/bin/env python3
"""Billing control plane: independent approval, immutable parents and SQL scope."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

_loader = importlib.util.spec_from_file_location('native_init_control', Path(__file__).with_name('native_init_control.py'))
INIT = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(INIT)
BASE = INIT.BASE
require = BASE.require


def validate_inputs(event, ref, sha, repository, attempt):
    operation = event.get('inputs', {}).get('operation')
    require(operation in ('native-billing-plan', 'native-billing'), 'explicit native Billing plan/apply required')
    normalized = {**event, 'inputs': {**event['inputs'],
        'operation': 'native-init-plan' if operation == 'native-billing-plan' else 'native-init'}}
    return INIT.validate_inputs(normalized, ref, sha, repository, attempt)


def validate_billing(contract):
    INIT.validate_initialization(contract['initialization'])
    billing = contract['billing']
    require(billing.get('format') == 1 and billing.get('owner') == 'ai-workspace-services/billing-service' and
        re.fullmatch('[0-9a-f]{40}', billing.get('commit', '')) and
        billing.get('migration_file') == 'sql/migrations/2026100701_cloud_vendor_costs.up.sql' and
        re.fullmatch('[0-9a-f]{64}', billing.get('migration_sha256', '')) and
        billing.get('expected_schema_version') == contract['initialization']['migration_version'] == 2026100601 and
        billing.get('target_schema_version') == 2026100701 and billing.get('business_tables') == ['cloud_vendor_costs'] and
        billing.get('no_business_seeds') is True and billing.get('database_cutover_approved') is False,
        'Billing additive manifest/source scope differs')


def validate_initialized(contract, run, workflow, artifact):
    require(contract.get('initialization_accepted') is True, 'successful real native initialization acceptance is pending')
    parent = contract['initialized']
    require(type(parent.get('run_id')) is int and parent['run_id'] > 0 and parent.get('run_attempt') == 1 and
        type(parent.get('artifact_id')) is int and parent['artifact_id'] > 0 and
        re.fullmatch('[0-9a-f]{40}', parent.get('toolkit_commit') or '') and
        re.fullmatch(r'v\d[0-9.r-]*', parent.get('release_tag') or '') and
        re.fullmatch('sha256:[0-9a-f]{64}', parent.get('artifact_digest') or '') and
        re.fullmatch('[0-9a-f]{64}', parent.get('receipt_sha256') or ''),
        'accepted initialization must bind real run/tag/artifact/checksums')
    require(run.get('id') == parent['run_id'] and run.get('run_attempt') == parent['run_attempt'] == 1 and
        run.get('repository', {}).get('full_name') == BASE.REPOSITORY and run.get('event') == 'workflow_dispatch' and
        run.get('status') == 'completed' and run.get('conclusion') == 'success' and
        run.get('head_sha') == parent['toolkit_commit'] and run.get('head_branch') == parent['release_tag'],
        'actual initialization run has not succeeded at the accepted immutable source')
    require(workflow.get('id') == run.get('workflow_id') and
        workflow.get('path') == '.github/workflows/selfhost-orchestrator.yml', 'initialization workflow differs')
    require(artifact.get('id') == parent['artifact_id'] and artifact.get('name') == 'prod-native-init-receipt' and
        artifact.get('expired') is False and artifact.get('workflow_run', {}).get('id') == parent['run_id'] and
        artifact.get('workflow_run', {}).get('head_sha') == parent['toolkit_commit'] and
        artifact.get('digest') == parent['artifact_digest'] and 0 < artifact.get('size_in_bytes', 0) <= 65536,
        'initialization artifact identity/digest/retention differs')


def validate_initialized_receipt(contract, archive):
    parent = contract['initialized']
    require(archive.stat().st_size <= 65536 and
        'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest() == parent['artifact_digest'],
        'downloaded initialization archive differs')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(len(entries) == 1 and entries[0].filename == 'prod-native-init-receipt.json' and
            not entries[0].is_dir() and entries[0].file_size <= 65536 and
            (entries[0].external_attr >> 16 & 0o170000) != 0o120000, 'initialization archive is unsafe')
        raw = zipped.read(entries[0])
    require(hashlib.sha256(raw).hexdigest() == parent['receipt_sha256'], 'original initialization receipt differs')
    receipt = json.loads(raw)
    spec = contract['initialization']
    require(receipt.get('stage') == 'native_schema_initialized' and receipt.get('result') == 'initialized' and
        receipt.get('environment') == 'prod' and receipt.get('host') == 'web-saas-prod' and
        receipt.get('database') == 'account' and receipt.get('schema_initialized') is True and
        receipt.get('schema_sha256') == spec['schema_sha256'] and
        receipt.get('migration_version') == spec['migration_version'] and
        receipt.get('business_tables') == spec['business_tables'] and receipt.get('business_rows') == 0 and
        receipt.get('accounts_commit') == spec['accounts_commit'] and receipt.get('image_digest') == spec['image_digest'] and
        receipt.get('writers_paused') is True and receipt.get('independent_disk_verified') is True and
        receipt.get('database_cutover_approved') is False,
        'initialization receipt does not establish the reviewed zero-row native target')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--contract', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'Billing schema requires explicit dispatch')
    dry_run = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()),
        os.environ['GITHUB_REF'], os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_RUN_ATTEMPT'])
    get = BASE.get_json
    run_id = os.environ['GITHUB_RUN_ID']
    INIT.validate_data_review(get('/environments/prod'), get('/actions/runs/' + run_id),
        get('/actions/runs/' + run_id + '/approvals'), run_id, os.environ['GITHUB_SHA'], os.environ['GITHUB_REF'])
    contract = json.loads(args.contract.read_text())
    validate_billing(contract)
    require(contract.get('initialization_accepted') is True, 'successful real native initialization acceptance is pending')
    for key in ('gitops_commit', 'iac_commit', 'playbooks_commit'):
        require(re.fullmatch('[0-9a-f]{40}', contract.get(key, '')), 'fixed execution owner SHA missing')
    source = contract['resource']
    run = get('/actions/runs/' + str(source['run_id']))
    BASE.validate_provenance(contract, run, get('/actions/workflows/' + str(run['workflow_id'])),
        get('/actions/artifacts/' + str(source['artifact_id'])))
    standby = contract['standby']
    run = get('/actions/runs/' + str(standby['run_id']))
    INIT.validate_standby(contract, run, get('/actions/workflows/' + str(run['workflow_id'])),
        get('/actions/artifacts/' + str(standby['artifact_id'])))
    parent = contract['initialized']
    run = get('/actions/runs/' + str(parent['run_id']))
    validate_initialized(contract, run, get('/actions/workflows/' + str(run['workflow_id'])),
        get('/actions/artifacts/' + str(parent['artifact_id'])))
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP'], prefix='native-billing-evidence-') as directory:
        path = Path(directory)
        INIT.download(parent['artifact_id'], path / 'initialized.zip')
        validate_initialized_receipt(contract, path / 'initialized.zip')
        INIT.download(standby['artifact_id'], path / 'standby.zip')
        INIT.validate_receipt(contract, path / 'standby.zip')
        INIT.download(source['artifact_id'], path / 'resource.zip')
        BASE.stage_archive(contract, path / 'resource.zip', args.destination)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('dry_run=' + str(dry_run).lower() + '\n')
            output.write('gitops_commit=' + contract['gitops_commit'] + '\n')
            output.write('billing_commit=' + contract['billing']['commit'] + '\n')
            output.write('cmdb_sha256=' + source['cmdb_sha256'] + '\n')
            output.write('data_gate_verified=true\n')
    print('Independent approval and actual parent initialization/standby/resource evidence verified; no database action performed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired, zipfile.BadZipFile):
        print('Native Billing control stopped; private API/artifact output withheld.')
        raise SystemExit(1)
