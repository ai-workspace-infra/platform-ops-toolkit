#!/usr/bin/env python3
"""Control plane only: validate immutable caller/resource provenance and artifact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile

REPOSITORY = 'ai-workspace-infra/platform-ops-toolkit'
RESOURCE_WORKFLOW = '.github/workflows/gcp-iac-pipeline.yml'
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_inputs(event, ref, sha, repository):
    inputs = event.get('inputs') or {}
    require(repository == REPOSITORY, 'caller repository differs')
    require(re.fullmatch(r'refs/tags/v\d[0-9.r-]*', ref), 'native standby requires an immutable release tag')
    require(re.fullmatch(r'[0-9a-f]{40}', sha), 'caller commit is invalid')
    required = {'operation': 'native-standby', 'vault_env_path': 'prod',
        'target_domains': 'web-saas', 'cloud_provider': 'gcp-cloud',
        'cloud_account': 'xworktech', 'target_domain_base': 'svc.plus',
        'dns_mode': 'none', 'runner_type': 'ubuntu-latest', 'offline_mode': 'off'}
    require(all(inputs.get(k) == v for k, v in required.items()), 'native standby target/control inputs differ')
    require(inputs.get('vault_addr', '') in ('', 'https://vault.svc.plus'), 'unapproved Vault endpoint')
    require(inputs.get('source_ref', '') in ('', sha), 'caller source override differs')
    require(not inputs.get('deploy_tag'), 'standby does not deploy application images')


def validate_provenance(contract, run, workflow, artifact):
    require(contract.get('resource_accepted') is True, 'new private SSH resource acceptance is pending')
    source = contract['resource']
    require(run.get('id') == source['run_id'] and run.get('run_attempt') == source['run_attempt'], 'resource run/attempt differs')
    require(run.get('repository', {}).get('full_name') == REPOSITORY, 'resource repository differs')
    require(run.get('event') == 'workflow_dispatch' and run.get('status') == 'completed' and
        run.get('conclusion') == 'success', 'resource run has not succeeded')
    require(run.get('head_sha') == source['toolkit_commit'] and run.get('head_branch') == source['release_tag'], 'resource immutable source differs')
    require(workflow.get('id') == run.get('workflow_id') and workflow.get('path') == RESOURCE_WORKFLOW, 'resource workflow differs')
    require(artifact.get('id') == source['artifact_id'] and
        artifact.get('name') == 'gcp-prod-web-saas-inventory' and artifact.get('expired') is False,
        'resource artifact identity/retention differs')
    require(artifact.get('workflow_run', {}).get('id') == source['run_id'] and
        artifact.get('workflow_run', {}).get('head_sha') == source['toolkit_commit'], 'artifact does not belong to accepted source run')
    require(artifact.get('digest') == source['artifact_digest'] and
        0 < artifact.get('size_in_bytes', 0) <= MAX_ARCHIVE_BYTES, 'artifact checksum/size differs')


def stage_archive(contract, archive, destination):
    source = contract['resource']
    require(archive.stat().st_size <= MAX_ARCHIVE_BYTES, 'resource archive too large')
    require('sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest() == source['artifact_digest'], 'downloaded artifact digest differs')
    require(not destination.exists(), 'resource destination must be fresh')
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        names = [entry.filename for entry in entries]
        require(len(names) == len(set(names)) and set(names) <= {'cmdb.json', 'inventory.ini', 'hosts_manifest.json'} and
            {'cmdb.json', 'inventory.ini'} <= set(names), 'archive is not the original flat resource inventory')
        require(sum(entry.file_size for entry in entries) <= MAX_ARCHIVE_BYTES and
            all(not entry.is_dir() and (entry.external_attr >> 16 & 0o170000) != 0o120000 for entry in entries),
            'resource archive contains unsafe entries')
        content = {entry.filename: z.read(entry) for entry in entries}
    require(hashlib.sha256(content['cmdb.json']).hexdigest() == source['cmdb_sha256'], 'canonical CMDB bytes differ')
    require(hashlib.sha256(content['inventory.ini']).hexdigest() == source['inventory_sha256'], 'original inventory bytes differ')
    cmdb = json.loads(content['cmdb.json'])
    host = cmdb.get('web-saas-prod') or {}
    require(cmdb.get('environment') == 'prod' and cmdb.get('project_id') == 'open-platform-prod' and
        cmdb.get('deploy_account') == 'github-actions-prod@open-platform-prod.iam.gserviceaccount.com' and
        host.get('provider') == 'gcp-cloud' and host.get('zone') == 'asia-east1-a' and
        host.get('provisioning_model') == 'STANDARD' and 'web_saas' in host.get('groups', []) and
        host.get('data_disk', {}).get('id') == 'projects/open-platform-prod/zones/asia-east1-a/disks/web-saas-prod-data' and
        host.get('data_disk', {}).get('mount_path') == '/data', 'canonical PROD resource contract differs')
    destination.mkdir(mode=0o700)
    for name, data in content.items():
        path = destination / name
        path.write_bytes(data)
        path.chmod(0o600)


def get_json(path):
    request = urllib.request.Request('https://api.github.com/repos/' + REPOSITORY + path,
        headers={'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--contract', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'native standby must be explicitly dispatched')
    validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()),
        os.environ['GITHUB_REF'], os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY'])
    contract = json.loads(args.contract.read_text())
    source = contract['resource']
    run = get_json('/actions/runs/' + str(source['run_id']))
    workflow = get_json('/actions/workflows/' + str(run['workflow_id']))
    artifact = get_json('/actions/artifacts/' + str(source['artifact_id']))
    validate_provenance(contract, run, workflow, artifact)
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP'], prefix='native-resource-') as temp:
        archive = Path(temp) / 'resource.zip'
        with archive.open('wb') as output:
            # gh handles authenticated GitHub redirects; stderr may include a
            # signed download URL, so it is never emitted or stored in evidence.
            result = subprocess.run(['gh', 'api', 'repos/' + REPOSITORY + '/actions/artifacts/' +
                str(source['artifact_id']) + '/zip'], stdout=output, stderr=subprocess.PIPE, timeout=120)
        require(result.returncode == 0, 'cannot download accepted resource artifact')
        stage_archive(contract, archive, args.destination)
    print('Accepted exact successful resource run and original PROD CMDB/inventory bytes; no host or database action performed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, urllib.error.URLError, zipfile.BadZipFile,
            subprocess.TimeoutExpired) as error:
        # Never render HTTP/signed URL errors, token headers or artifact contents.
        print('Native standby control gate stopped: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__))
        raise SystemExit(1)
