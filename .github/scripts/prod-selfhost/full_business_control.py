#!/usr/bin/env python3
"""Full-business control only: independent review, immutable parents and scope.

No host/database executor. Playbooks owns replication and IaC owns access.
Point-in-time equality never grants the final single-writer/cutover approval.
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

_loader = importlib.util.spec_from_file_location('native_billing_control', Path(__file__).with_name('native_billing_control.py'))
BILLING = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(BILLING)
INIT, BASE, require = BILLING.INIT, BILLING.BASE, BILLING.require
MODES = {'native-business-plan': 'preview', 'native-business-copy': 'copy', 'native-business-compare': 'compare'}
ACCOUNTS_SQL = '842cef3beb98ef819dc854ecdf5f85683233641a0cd85a9156b30ad59f7e0206'
BILLING_SQL = 'a7133f3ef2ea9013a055cfd1442a7488d2b837f289e0f5d9b61624d4fde9bc53'


def validate_inputs(event, ref, sha, repository, attempt):
    operation = event.get('inputs', {}).get('operation')
    require(operation in MODES, 'explicit full-business operation required')
    normalized = {**event, 'inputs': {**event['inputs'], 'operation': 'native-init-plan'}}
    INIT.validate_inputs(normalized, ref, sha, repository, attempt)
    return MODES[operation]


def validate_contract(contract, require_source=True):
    require(contract.get('schema') == 1 and contract.get('scope') == 'prod-full-business-only', 'full-business scope differs')
    BILLING.validate_billing(contract)
    initial, transfer, source = (contract[key] for key in ('initialization', 'transfer', 'source'))
    for key in ('gitops_commit', 'iac_commit', 'playbooks_commit'):
        require(re.fullmatch('[0-9a-f]{40}', contract.get(key, '')), 'fixed execution owner SHA missing')
    require(initial['migration_version'] == 2026100601 and initial['schema_sha256'] == ACCOUNTS_SQL and
        contract['billing']['migration_sha256'] == BILLING_SQL, 'qualified native schema boundary differs')
    require(transfer.get('schema') == 1 and transfer.get('environment') == 'prod' and
        transfer.get('host') == 'web-saas-prod' and transfer.get('database') == 'account' and
        re.fullmatch('[0-9a-f]{40}', transfer.get('accounts_commit', '')) and
        transfer.get('image') == 'ghcr.io/ai-workspace-services/accounts:sha-' + transfer['accounts_commit'] and
        re.fullmatch('sha256:[0-9a-f]{64}', transfer.get('image_digest', '')) and
        transfer.get('schema_sha256') == ACCOUNTS_SQL and transfer.get('billing_schema_sha256') == BILLING_SQL and
        transfer.get('migration_version') == 2026100701 and transfer.get('batch_size') == 1000 and
        transfer.get('business_tables') == sorted(initial['business_tables'] + ['cloud_vendor_costs']) and
        transfer.get('database_cutover_approved') is False, 'full-business image/table/version scope differs')
    require(source.get('role') == 'readonly_release' and source.get('tls_required') is True and
        source.get('direction') == 'prod-supabase-to-prod-selfhost', 'source readonly/direction boundary differs')
    if require_source:
        require(source.get('ready') is True and re.fullmatch('[0-9a-f]{64}', source.get('identity_sha256') or ''),
            'approved source identity/readonly connection contract is pending')
    else:
        require((source.get('ready') is False and source.get('identity_sha256') is None) or
            (source.get('ready') is True and re.fullmatch('[0-9a-f]{64}', source.get('identity_sha256') or '')),
            'source readiness must be explicit; no fabricated pending identity')


def parent_details(contract, kind):
    names = {'billing': ('billing_accepted', 'upgraded', 'prod-native-billing-receipt'),
        'copy': ('copy_accepted', 'copied', 'prod-full-business-receipt')}
    accepted, key, name = names[kind]
    require(contract.get(accepted) is True, 'successful real ' + kind + ' acceptance is pending')
    parent = contract[key]
    require(type(parent.get('run_id')) is int and parent['run_id'] > 0 and
        type(parent.get('run_attempt')) is int and parent['run_attempt'] == 1 and
        type(parent.get('artifact_id')) is int and parent['artifact_id'] > 0 and
        re.fullmatch('[0-9a-f]{40}', parent.get('toolkit_commit') or '') and
        re.fullmatch(r'v\d[0-9.r-]*', parent.get('release_tag') or '') and
        re.fullmatch('sha256:[0-9a-f]{64}', parent.get('artifact_digest') or '') and
        re.fullmatch('[0-9a-f]{64}', parent.get('receipt_sha256') or ''), 'accepted parent must bind real immutable evidence')
    return parent, name


def validate_parent(contract, kind, run, workflow, artifact):
    parent, name = parent_details(contract, kind)
    require(run.get('id') == parent['run_id'] and run.get('run_attempt') == 1 and
        run.get('repository', {}).get('full_name') == BASE.REPOSITORY and run.get('event') == 'workflow_dispatch' and
        run.get('status') == 'completed' and run.get('conclusion') == 'success' and
        run.get('head_sha') == parent['toolkit_commit'] and run.get('head_branch') == parent['release_tag'],
        'actual parent run did not succeed at accepted immutable source')
    require(workflow.get('id') == run.get('workflow_id') and
        workflow.get('path') == '.github/workflows/selfhost-orchestrator.yml', 'parent workflow differs')
    require(artifact.get('id') == parent['artifact_id'] and artifact.get('name') == name and
        artifact.get('expired') is False and artifact.get('workflow_run', {}).get('id') == parent['run_id'] and
        artifact.get('workflow_run', {}).get('head_sha') == parent['toolkit_commit'] and
        artifact.get('digest') == parent['artifact_digest'] and
        type(artifact.get('size_in_bytes')) is int and 0 < artifact['size_in_bytes'] <= 65536,
        'parent artifact identity/digest/retention differs')


def validate_parent_receipt(contract, kind, archive):
    parent, name = parent_details(contract, kind)
    require(0 < archive.stat().st_size <= 65536 and
        'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest() == parent['artifact_digest'], 'downloaded parent archive differs')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(len(entries) == 1 and entries[0].filename == name + '.json' and
            not entries[0].is_dir() and 0 < entries[0].file_size <= 65536 and
            (entries[0].external_attr >> 16 & 0o170000) != 0o120000, 'unsafe parent archive')
        raw = zipped.read(entries[0])
    require(hashlib.sha256(raw).hexdigest() == parent['receipt_sha256'], 'original parent receipt bytes differ')
    receipt = json.loads(raw)
    require(receipt.get('environment') == 'prod' and receipt.get('host') == 'web-saas-prod' and
        receipt.get('database') == 'account' and receipt.get('migration_version') == 2026100701 and
        receipt.get('business_tables') == contract['transfer']['business_tables'] and
        receipt.get('writers_paused') is True and receipt.get('independent_disk_verified') is True and
        receipt.get('database_cutover_approved') is False, 'parent target/schema/writer proof differs')
    if kind == 'billing':
        initial, billing = contract['initialization'], contract['billing']
        require(receipt.get('stage') == 'native_billing_schema_upgraded' and receipt.get('result') == 'upgraded' and
            receipt.get('business_rows') == 0 and receipt.get('target_version') == 2026100701 and
            receipt.get('billing_commit') == billing['commit'] and receipt.get('migration_sha256') == BILLING_SQL and
            receipt.get('accounts_commit') == initial['accounts_commit'] and receipt.get('image_digest') == initial['image_digest'],
            'parent does not establish real zero-row Billing upgrade')
    else:
        transfer = contract['transfer']
        require(receipt.get('stage') == 'full_business_baseline_copied' and receipt.get('result') == 'copied' and
            receipt.get('format') == 1 and receipt.get('accounts_commit') == transfer['accounts_commit'] and
            receipt.get('image_digest') == transfer['image_digest'] and receipt.get('schema_sha256') == ACCOUNTS_SQL and
            receipt.get('billing_schema_sha256') == BILLING_SQL and receipt.get('batch_size') == 1000 and
            receipt.get('source_identity_sha256') == contract['source']['identity_sha256'] and
            receipt.get('source_read_only') is True and receipt.get('full_business_equal') is True and
            receipt.get('target_writes') is True and receipt.get('source_writers_paused') is False and
            receipt.get('final_catchup_complete') is False and
            all(re.fullmatch('[0-9a-f]{64}', receipt.get(key, '')) for key in ('source_snapshot_sha256', 'source_catalog_sha256')) and
            type(receipt.get('source_table_count')) is int and 44 <= receipt['source_table_count'] <= 53 and
            type(receipt.get('user_count')) is int and receipt['user_count'] > 0, 'copy parent is not complete baseline evidence')
        tables = receipt.get('tables')
        require(isinstance(tables, dict) and sorted(tables) == transfer['business_tables'], 'all 53 table proofs are required')
        for proof in tables.values():
            require(isinstance(proof, dict) and set(proof) == {'rows', 'sha256'} and type(proof['rows']) is int and
                proof['rows'] >= 0 and re.fullmatch('[0-9a-f]{64}', proof.get('sha256') or ''), 'invalid per-table digest evidence')
        require(tables['users']['rows'] == receipt['user_count'], 'user count evidence differs')
        times = []
        for key in ('snapshot_started_at', 'completed_at'):
            value = receipt.get(key)
            require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z', value), 'snapshot timestamp differs')
            times.append(datetime.fromisoformat(value.replace('Z', '+00:00')))
        require(0 <= (times[1] - times[0]).total_seconds() <= 1800, 'snapshot duration exceeds reviewed bound')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--contract', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'full-business data requires explicit dispatch')
    mode = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), os.environ['GITHUB_REF'],
        os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_RUN_ATTEMPT'])
    contract = json.loads(args.contract.read_text())
    review_required = INIT.validate_data_review_config(contract, 'prod-full-business-only')
    get, run_id = BASE.get_json, os.environ['GITHUB_RUN_ID']
    INIT.validate_data_review(get('/environments/prod'), get('/actions/runs/' + run_id),
        get('/actions/runs/' + run_id + '/approvals'), run_id, os.environ['GITHUB_SHA'], os.environ['GITHUB_REF'],
        review_required)
    validate_contract(contract)
    require(contract.get('initialization_accepted') is True, 'real initialization acceptance is pending')
    source, standby, initialized = (contract[key] for key in ('resource', 'standby', 'initialized'))
    checks = [(source, BASE.validate_provenance), (standby, INIT.validate_standby), (initialized, BILLING.validate_initialized)]
    for kind in ('billing', 'copy') if mode == 'compare' else ('billing',):
        parent, _ = parent_details(contract, kind)
        checks.append((parent, lambda c, r, w, a, kind=kind: validate_parent(c, kind, r, w, a)))
    for parent, check in checks:
        run = get('/actions/runs/' + str(parent['run_id']))
        check(contract, run, get('/actions/workflows/' + str(run['workflow_id'])), get('/actions/artifacts/' + str(parent['artifact_id'])))
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP'], prefix='full-business-evidence-') as directory:
        path = Path(directory)
        for kind in ('billing', 'copy') if mode == 'compare' else ('billing',):
            parent, _ = parent_details(contract, kind)
            INIT.download(parent['artifact_id'], path / (kind + '.zip'))
            validate_parent_receipt(contract, kind, path / (kind + '.zip'))
        INIT.download(initialized['artifact_id'], path / 'initialized.zip')
        BILLING.validate_initialized_receipt(contract, path / 'initialized.zip')
        INIT.download(standby['artifact_id'], path / 'standby.zip')
        INIT.validate_receipt(contract, path / 'standby.zip')
        INIT.download(source['artifact_id'], path / 'resource.zip')
        BASE.stage_archive(contract, path / 'resource.zip', args.destination)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key, value in dict(mode=mode, gitops_commit=contract['gitops_commit'],
                cmdb_sha256=source['cmdb_sha256'], data_gate_verified='true').items():
                output.write(key + '=' + value + '\n')
    review_message = ('Independent approval' if review_required else
                      'Controlled independent data review requirement disabled')
    print(review_message + ', reviewed source and real immutable parents verified; no database action or cutover authorized.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Full-business control stopped before runtime credentials or host access; private output withheld.')
        raise SystemExit(1)
