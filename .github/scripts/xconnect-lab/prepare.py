"""Protected runtime files only. Never print provider responses or credentials."""
import datetime
import base64
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


def vultr(path):
    request = urllib.request.Request('https://api.vultr.com/v2/' + path,
                                    headers={'Authorization': 'Bearer ' + os.environ['VULTR_API_KEY']})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    action, directory, declaration = sys.argv[1:]
    folder = Path(directory)
    spec = json.loads(Path(declaration).read_text())['spec']
    run = os.environ['TF_VAR_run_id']
    gateway_provider = spec.get('gateway_provider', 'aws-spot')
    if gateway_provider not in ('aws-spot', 'vultr'):
        raise ValueError('gateway_provider must be aws-spot or vultr')
    if action == 'backend':
        save(folder / 'backend.json', {
            'bucket': os.environ['TF_STATE_BUCKET'],
            'key': f'sit/xconnect-lab/{run}/terraform.tfstate',
            'region': os.environ['TF_STATE_REGION'],
            'endpoints': {'s3': os.environ['TF_STATE_ENDPOINT']},
            'access_key': os.environ['TF_STATE_ACCESS_KEY'],
            'secret_key': os.environ['TF_STATE_SECRET_KEY'],
            'token': '',
            'skip_credentials_validation': True, 'skip_region_validation': True,
            'skip_requesting_account_id': True, 'skip_metadata_api_check': True,
            'use_path_style': True})
        return
    zero = spec.get('zero', {'accounts_api_url': 'https://accounts.svc.plus', 'portal_url': 'https://portal.svc.plus'})
    values = {'run_id': run, 'gateway_provider': gateway_provider,
              'aws_region': spec['aws']['region'],
              'aws_instance_type': spec['aws']['instance_type'],
              'vpc_cidr': spec['aws']['vpc_cidr'],
              'vultr_region': spec.get('vultr', {}).get('region', ''),
              'vultr_plan': spec.get('vultr', {}).get('plan', ''),
              'zero_accounts_api_url': zero['accounts_api_url'],
              'zero_portal_url': zero['portal_url']}
    if action == 'resources':
        if len(base64.b64decode(os.environ['LAB_SIGNING_KEY'], validate=True)) != 32:
            raise ValueError('Vault SIGNING_KEY must be a base64 Ed25519 32-byte seed')
        uuid.UUID(os.environ['LAB_VLESS_ID'])
        if len(os.environ['LAB_ADMIN_TOKEN']) < 32:
            raise ValueError('Vault ADMIN_TOKEN must contain at least 32 characters')
        vultr_os_id = 0
        if gateway_provider == 'vultr':
            if not os.environ.get('VULTR_API_KEY'):
                raise ValueError('VULTR_API_KEY is required only when gateway_provider=vultr')
            # Catalog/account GET requests; never create resources in preflight.
            vultr('account')
            available = vultr('regions/' + spec['vultr']['region'] + '/availability')['available_plans']
            if spec['vultr']['plan'] not in available:
                raise ValueError('Declared Vultr plan unavailable in region')
            matches = [x for x in vultr('os')['os'] if x['name'] == spec['vultr']['os_name']]
            if len(matches) != 1:
                raise ValueError('Declared Vultr OS must resolve uniquely')
            vultr_os_id = matches[0]['id']
        ami = subprocess.check_output(['aws', 'ssm', 'get-parameter', '--name', spec['aws']['ami_ssm_parameter'],
                                       '--query', 'Parameter.Value', '--output', 'text'], text=True).strip()
        images = json.loads(subprocess.check_output(['aws', 'ec2', 'describe-images', '--image-ids', ami, '--output', 'json']))['Images']
        if len(images) != 1 or images[0]['Architecture'] != 'x86_64' or images[0]['OwnerId'] != '099720109477':
            raise ValueError('Expected Canonical x86_64 Ubuntu AMI')
        with urllib.request.urlopen('https://checkip.amazonaws.com', timeout=15) as response:
            ip = str(ipaddress.IPv4Address(response.read().decode().strip()))
        values.update(aws_ami=ami, vultr_os_id=vultr_os_id, runner_cidr=ip + '/32',
                      ssh_public_key=(folder / 'id_ed25519.pub').read_text().strip(),
                      expires_at=(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=spec['ttl_minutes'])).strftime('%Y-%m-%dT%H:%M:%SZ'))
    elif action == 'cleanup':
        root_module = json.loads((folder / 'state.json').read_text()).get('values', {}).get('root_module', {})
        if root_module.get('child_modules'):
            raise ValueError('Unexpected nested module in dedicated lab state')
        resources = root_module.get('resources', [])
        allowed = {'aws_vpc.lab', 'aws_subnet.lab', 'aws_internet_gateway.lab', 'aws_route_table.lab',
                   'aws_route_table_association.lab', 'aws_security_group.client', 'aws_security_group.gateway',
                   'aws_key_pair.lab', 'aws_instance.client', 'aws_instance.gateway[0]',
                   'vultr_ssh_key.lab[0]', 'vultr_firewall_group.lab[0]',
                   'vultr_firewall_rule.ssh[0]', 'vultr_firewall_rule.client[0]',
                   'vultr_firewall_rule.zero[0]', 'vultr_instance.gateway[0]'}
        for resource in resources:
            if resource['address'] not in allowed:
                raise ValueError('Unexpected resource in lab state; refusing cleanup')
            v = resource['values']
            if resource['type'].startswith('aws_') and 'tags_all' in v and v['tags_all'].get('LabRun') != run:
                raise ValueError('AWS lab ownership mismatch')
            if resource['type'] == 'vultr_instance' and run not in v.get('tags', []):
                raise ValueError('Vultr lab ownership mismatch')
        # Destroy does not create anything; variables needed only to decode configuration.
        values.update(aws_ami='ami-unused-for-destroy', vultr_os_id=0, runner_cidr='127.0.0.1/32',
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
