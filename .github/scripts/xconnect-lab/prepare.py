"""Protected runtime files only. Never print provider responses or credentials."""
import datetime
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import uuid


def save(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def main():
    action, directory, declaration = sys.argv[1:]
    folder = Path(directory)
    spec = json.loads(Path(declaration).read_text())['spec']
    run = os.environ['TF_VAR_run_id']
    gateway_provider = spec['gateway_provider']
    if gateway_provider != 'aws-spot':
        raise ValueError('UAT validation requires gateway_provider=aws-spot')
    if action == 'backend':
        save(folder / 'backend.json', {
            'bucket': os.environ['TF_STATE_BUCKET'],
            'key': f'uat/xconnect-lab/{run}/terraform.tfstate',
            'region': os.environ['TF_STATE_REGION'],
            'endpoints': {'s3': os.environ['TF_STATE_ENDPOINT']},
            'access_key': os.environ['TF_STATE_ACCESS_KEY'],
            'secret_key': os.environ['TF_STATE_SECRET_KEY'],
            'token': '',
            'skip_credentials_validation': True, 'skip_region_validation': True,
            'skip_requesting_account_id': True, 'skip_metadata_api_check': True,
            'use_path_style': True})
        return
    zero = spec['zero']
    values = {'run_id': run, 'gateway_provider': gateway_provider,
              'aws_region': spec['aws']['region'],
              'aws_client_instance_type': spec['nodes']['one']['instance_type'],
              'aws_gateway_instance_type': spec['nodes']['gateway']['instance_type'],
              'zero_accounts_api_url': zero['accounts_api_url'],
              'zero_portal_url': zero['portal_url']}
    if action == 'resources':
        uuid.UUID(os.environ['LAB_VLESS_ID'])
        if len(os.environ['ZERO_SERVICE_TOKEN']) < 32:
            raise ValueError('Vault ZERO_SERVICE_TOKEN must contain at least 32 characters')
        owner_email = os.environ['ZERO_OWNER_EMAIL'].strip()
        if '@' not in owner_email or owner_email.startswith('@') or owner_email.endswith('@'):
            raise ValueError('Vault ZERO_OWNER_EMAIL must be an email address')
        ami = subprocess.check_output(['aws', 'ssm', 'get-parameter', '--name', spec['aws']['ami_ssm_parameter'],
                                       '--query', 'Parameter.Value', '--output', 'text'], text=True).strip()
        images = json.loads(subprocess.check_output(['aws', 'ec2', 'describe-images', '--image-ids', ami, '--output', 'json']))['Images']
        if len(images) != 1 or images[0]['Architecture'] != 'arm64' or images[0]['OwnerId'] != '099720109477':
            raise ValueError('Expected Canonical ARM64 Ubuntu AMI')
        with urllib.request.urlopen('https://checkip.amazonaws.com', timeout=15) as response:
            ip = str(ipaddress.IPv4Address(response.read().decode().strip()))
        values.update(aws_ami=ami, runner_cidr=ip + '/32',
                      ssh_public_key=(folder / 'id_ed25519.pub').read_text().strip(),
                      expires_at=(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=spec['ttl_minutes'])).strftime('%Y-%m-%dT%H:%M:%SZ'))
    elif action == 'cleanup':
        root_module = json.loads((folder / 'state.json').read_text()).get('values', {}).get('root_module', {})
        if root_module.get('child_modules'):
            raise ValueError('Unexpected nested module in dedicated lab state')
        resources = root_module.get('resources', [])
        allowed = {'aws_security_group.client', 'aws_security_group.gateway',
                   'aws_instance.client', 'aws_instance.gateway'}
        for resource in resources:
            if resource.get('mode') == 'data':
                continue
            if resource['address'] not in allowed:
                raise ValueError('Unexpected resource in lab state; refusing cleanup')
            v = resource['values']
            if resource['type'].startswith('aws_') and 'tags_all' in v and v['tags_all'].get('LabRun') != run:
                raise ValueError('AWS lab ownership mismatch')
        # Destroy does not create anything; variables needed only to decode configuration.
        values.update(aws_ami='ami-unused-for-destroy', runner_cidr='127.0.0.1/32',
                      ssh_public_key='unused-for-destroy', expires_at='1970-01-01T00:00:00Z')
    else:
        raise ValueError('Unknown operation')
    save(folder / 'variables.json', values)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # HTTP bodies, subprocess output and credential-bearing request objects stay private.
        print(f'Lab preparation failed ({type(exc).__name__}); check declared inputs and account permissions.', file=sys.stderr)
        sys.exit(1)
