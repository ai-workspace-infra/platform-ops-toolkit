#!/usr/bin/env python3
"""Native init control only: provenance/approval/artifacts, no host or DB executor."""
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

_spec = importlib.util.spec_from_file_location('native_standby_control', Path(__file__).with_name('native_standby_control.py'))
BASE = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(BASE)
require = BASE.require


def validate_inputs(event, ref, sha, repository, attempt):
    operation = event.get('inputs', {}).get('operation')
    require(operation in ('native-init-plan', 'native-init'), 'explicit native init plan/apply required')
    require(attempt == '1', 'native initialization reruns refused; dispatch a new reviewed run')
    normalized = {**event, 'inputs': {**event['inputs'], 'operation': 'native-standby'}}
    BASE.validate_inputs(normalized, ref, sha, repository)
    return operation == 'native-init-plan'


def validate_data_review_config(contract, expected_scope):
    require(isinstance(contract, dict) and contract.get('scope') == expected_scope,
            'native data review contract scope differs')
    required = contract.get('independent_data_review_required')
    require(type(required) is bool, 'native data review policy must be an explicit boolean')
    return required


def validate_data_review(environment, run, reviews, run_id, sha, ref, require_independent=True):
    require(run.get('id') == int(run_id) and run.get('run_attempt') == 1 and
            run.get('event') == 'workflow_dispatch' and run.get('head_sha') == sha and
            run.get('head_branch') == ref.removeprefix('refs/tags/') and
            run.get('repository', {}).get('full_name') == BASE.REPOSITORY,
            'current native data run provenance differs')
    if not require_independent:
        return
    require(environment.get('name') == 'prod' and any(rule.get('type') == 'required_reviewers' and
            rule.get('prevent_self_review') is True and rule.get('reviewers')
            for rule in environment.get('protection_rules', [])),
            'PROD data operations require configured independent reviewers and prevent_self_review=true')
    actors = {actor.get('login') for actor in (run.get('actor') or {}, run.get('triggering_actor') or {})}
    actors.discard(None)
    require(actors and any(review.get('state') == 'approved' and review.get('user', {}).get('login') and
            review['user']['login'] not in actors and any(item.get('id') == environment['id'] and
            item.get('name') == 'prod' for item in review.get('environments', [])) for review in reviews),
            'current native initialization run has no independent PROD approval')


def validate_standby(contract, run, workflow, artifact):
    require(contract.get('standby_accepted') is True, 'successful real PostgreSQL standby acceptance is pending')
    source = contract['standby']
    require(run.get('id') == source['run_id'] and run.get('run_attempt') == source['run_attempt'] == 1 and
            run.get('repository', {}).get('full_name') == BASE.REPOSITORY and
            run.get('event') == 'workflow_dispatch' and run.get('status') == 'completed' and
            run.get('conclusion') == 'success' and run.get('head_sha') == source['toolkit_commit'] and
            run.get('head_branch') == source['release_tag'], 'real standby run has not succeeded at the accepted source')
    require(workflow.get('id') == run.get('workflow_id') and workflow.get('path') == '.github/workflows/selfhost-orchestrator.yml',
            'standby evidence workflow differs')
    require(artifact.get('id') == source['artifact_id'] and artifact.get('name') == 'prod-native-standby-receipt' and
            artifact.get('expired') is False and artifact.get('workflow_run', {}).get('id') == source['run_id'] and
            artifact.get('workflow_run', {}).get('head_sha') == source['toolkit_commit'] and
            artifact.get('digest') == source['artifact_digest'] and 0 < artifact.get('size_in_bytes', 0) <= 65536,
            'standby receipt artifact identity/digest/retention differs')


def validate_initialization(spec):
    require(spec.get('schema') == 1 and spec.get('environment') == 'prod' and
            spec.get('host') == 'web-saas-prod' and spec.get('database') == 'account', 'native schema target differs')
    require(re.fullmatch(r'[0-9a-f]{40}', spec.get('accounts_commit', '')) and
            spec.get('image') == 'ghcr.io/ai-workspace-services/accounts:sha-' + spec['accounts_commit'] and
            re.fullmatch(r'sha256:[0-9a-f]{64}', spec.get('image_digest', '')) and
            re.fullmatch(r'[0-9a-f]{64}', spec.get('schema_sha256', '')), 'native schema immutable image/hash differs')
    tables = spec.get('business_tables')
    require(isinstance(tables, list) and len(tables) == spec.get('business_table_count') == 52 and
            all(isinstance(table, str) and re.fullmatch('[a-z][a-z0-9_]*', table) for table in tables) and
            tables == sorted(set(tables)) and type(spec.get('migration_version')) is int and
            spec['migration_version'] > 0, 'native business scope/version differs')


def validate_receipt(contract, archive):
    require(archive.stat().st_size <= 65536 and 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest() ==
            contract['standby']['artifact_digest'], 'downloaded standby receipt digest differs')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(len(entries) == 1 and entries[0].filename == 'prod-native-standby-receipt.json' and
                not entries[0].is_dir() and entries[0].file_size <= 65536 and
                (entries[0].external_attr >> 16 & 0o170000) != 0o120000, 'standby receipt archive is unsafe')
        raw = zipped.read(entries[0])
    require(hashlib.sha256(raw).hexdigest() == contract['standby']['receipt_sha256'], 'original standby receipt bytes differ')
    receipt = json.loads(raw)
    require(receipt.get('stage') == 'database_standby' and receipt.get('environment') == 'prod' and
            receipt.get('host') == 'web-saas-prod' and receipt.get('gitops_commit') == contract['gitops_commit'] and
            receipt.get('postgres_major') == 17 and receipt.get('independent_disk_verified') is True and
            receipt.get('writers_paused') is True and receipt.get('schema_initialized') is False and
            receipt.get('database_cutover_approved') is False, 'standby receipt does not establish an empty paused target')


def download(artifact_id, path):
    with path.open('wb') as output:
        result = subprocess.run(['gh', 'api', 'repos/' + BASE.REPOSITORY + '/actions/artifacts/' + str(artifact_id) + '/zip'],
            stdout=output, stderr=subprocess.PIPE, timeout=120)
    require(result.returncode == 0, 'cannot retrieve exact accepted artifact')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--contract', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'native schema must be explicitly dispatched')
    dry_run = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()),
        os.environ['GITHUB_REF'], os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_RUN_ATTEMPT'])
    contract = json.loads(args.contract.read_text())
    review_required = validate_data_review_config(contract, 'prod-native-init-only')
    get = BASE.get_json
    run_id = os.environ['GITHUB_RUN_ID']
    validate_data_review(get('/environments/prod'), get('/actions/runs/' + run_id),
        get('/actions/runs/' + run_id + '/approvals'), run_id, os.environ['GITHUB_SHA'], os.environ['GITHUB_REF'],
        review_required)
    validate_initialization(contract['initialization'])
    for key in ('gitops_commit', 'iac_commit', 'playbooks_commit'):
        require(re.fullmatch('[0-9a-f]{40}', contract.get(key, '')), 'fixed execution owner SHA missing')
    source = contract['resource']
    run = get('/actions/runs/' + str(source['run_id']))
    BASE.validate_provenance(contract, run, get('/actions/workflows/' + str(run['workflow_id'])),
                             get('/actions/artifacts/' + str(source['artifact_id'])))
    standby = contract['standby']
    run = get('/actions/runs/' + str(standby['run_id']))
    validate_standby(contract, run, get('/actions/workflows/' + str(run['workflow_id'])),
                     get('/actions/artifacts/' + str(standby['artifact_id'])))
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP'], prefix='native-init-evidence-') as directory:
        path = Path(directory)
        download(standby['artifact_id'], path / 'standby.zip')
        validate_receipt(contract, path / 'standby.zip')
        download(source['artifact_id'], path / 'resource.zip')
        BASE.stage_archive(contract, path / 'resource.zip', args.destination)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('dry_run=' + str(dry_run).lower() + '\n')
            output.write('gitops_commit=' + contract['gitops_commit'] + '\n')
            output.write('cmdb_sha256=' + source['cmdb_sha256'] + '\n')
            output.write('data_gate_verified=true\n')
    review_message = ('Independent PROD approval' if review_required else
                      'Controlled independent PROD data review requirement disabled')
    print(review_message + ', real standby and original resource evidence verified; no database action performed.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # API and signed redirect failures can include credentials; no raw error.
        print('Native schema control stopped before runtime credentials or host access.')
        raise SystemExit(1)
