"""Protected runtime files only. Never print provider responses or credentials."""
import datetime
import base64
import ipaddress
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import urllib.request
import uuid


DESKTOP_WINDOWS = {0, 10, 20}
NODE_WINDOWS = {'0', '10', '20', 'until-expiry'}
PUBLIC_HANDOFF_KEYS = {
    'run', 'expires_at', 'network_id', 'gateway_id', 'gateway_public_key',
    'gateway_endpoint', 'accounts_url', 'portal_url', 'instances',
    'expected_device_ids', 'verification',
}
PUBLIC_ENDPOINT_KEYS = {'host', 'port', 'server_name'}
PUBLIC_INSTANCE_GROUP_KEYS = {'gateway', 'linux_one'}
PUBLIC_INSTANCE_KEYS = {'instance_id', 'public_ip', 'private_ip'}
PUBLIC_EXPECTED_DEVICE_KEYS = {'darwin', 'windows'}
PUBLIC_VERIFICATION_KEYS = {'target', 'expected_marker'}
FORMAL_ACCOUNTS_URL = 'https://accounts-uat.onwalk.net'
FORMAL_PORTAL_URL = 'https://console-cloudflare-uat.onwalk.net/panel/xconnect-zero'


def save(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def validate_desktop_validation(spec, window):
    """Return the exact IAC ingress list allowed for the requested window."""
    if window not in DESKTOP_WINDOWS:
        raise ValueError('desktop_join_window_minutes must be 0, 10, or 20')
    if window == 0:
        return []
    desktop = spec.get('desktop_validation')
    if not isinstance(desktop, dict) or desktop.get('enabled') is not True:
        raise ValueError('desktop_validation.enabled must be true for a desktop join window')
    if desktop.get('max_join_window_minutes') != 20:
        raise ValueError('desktop_validation.max_join_window_minutes must be 20')
    if desktop.get('transport') != 'vless-tls-xudp' or desktop.get('public_wireguard_ingress') is not False:
        raise ValueError('desktop_validation transport or WireGuard ingress policy is incompatible')
    cidrs = desktop.get('ingress_cidrs')
    if not isinstance(cidrs, list) or not 1 <= len(cidrs) <= 2:
        raise ValueError('desktop_validation.ingress_cidrs must contain one or two IPv4 /32 values')
    if any(not isinstance(cidr, str) or not cidr for cidr in cidrs) or len(set(cidrs)) != len(cidrs):
        raise ValueError('desktop_validation.ingress_cidrs must be non-empty and unique')
    for cidr in cidrs:
        try:
            interface = ipaddress.ip_interface(cidr)
        except ValueError as exc:
            raise ValueError('desktop_validation.ingress_cidrs must be canonical IPv4 /32 values') from exc
        if interface.version != 4 or interface.network.prefixlen != 32 or str(interface) != cidr:
            raise ValueError('desktop_validation.ingress_cidrs must be canonical IPv4 /32 values')
    if desktop.get('platforms') != ['darwin', 'windows']:
        raise ValueError('desktop_validation.platforms must be exactly [darwin, windows]')
    return cidrs


def validate_gateway_transport_ingress(spec, requested=''):
    """Validate the ephemeral public allowlist for Gateway TCP 443.

    The reviewed GitOps declaration authorizes the exposure policy, while the
    workflow dispatch value supplies the current controlled-node egress IPs.
    No address is persisted in GitOps.
    """
    transport = spec.get('gateway_transport')
    if not isinstance(transport, dict) or transport.get('enabled') is not True:
        raise ValueError('gateway_transport.enabled must be true')
    if transport.get('port') != 443 or transport.get('transport') != 'vless-tls-xudp':
        raise ValueError('Gateway public transport must be VLESS/TLS on TCP 443')
    if transport.get('public_wireguard_ingress') is not False:
        raise ValueError('Gateway public transport must not expose WireGuard UDP')
    raw = str(requested or '').strip()
    cidrs = [] if not raw else [item.strip() for item in raw.split(',')]
    if len(cidrs) > 2 or any(not isinstance(cidr, str) or not cidr for cidr in cidrs):
        raise ValueError('Gateway transport ingress must contain at most two IPv4 /32 values')
    if len(set(cidrs)) != len(cidrs):
        raise ValueError('Gateway transport ingress must be unique')
    for cidr in cidrs:
        try:
            interface = ipaddress.ip_interface(cidr)
        except ValueError as exc:
            raise ValueError('Gateway transport ingress must be canonical IPv4 /32 values') from exc
        if interface.version != 4 or interface.network.prefixlen != 32 or str(interface) != cidr:
            raise ValueError('Gateway transport ingress must be canonical IPv4 /32 values')
    return cidrs


def validate_ssh_debug_access(spec, requested=None):
    """Return a narrowly scoped, temporary operator SSH allowlist.

    The workflow dispatch value is preferred so a changing operator egress IP
    never has to be committed to public GitOps. The declaration remains a
    backwards-compatible empty fallback for offline callers.
    """
    if requested is None:
        debug_access = spec.get('debug_access') or {}
        if not isinstance(debug_access, dict):
            raise ValueError('debug_access must be an object')
        cidrs = debug_access.get('ssh_ingress_cidrs', [])
    else:
        raw = str(requested).strip()
        cidrs = [] if not raw else [item.strip() for item in raw.split(',')]
    if not isinstance(cidrs, list) or len(cidrs) > 2:
        raise ValueError('debug_access.ssh_ingress_cidrs must contain at most two IPv4 /32 values')
    if any(not isinstance(cidr, str) or not cidr for cidr in cidrs) or len(set(cidrs)) != len(cidrs):
        raise ValueError('debug_access.ssh_ingress_cidrs must be non-empty and unique')
    for cidr in cidrs:
        try:
            interface = ipaddress.ip_interface(cidr)
        except ValueError as exc:
            raise ValueError('debug_access.ssh_ingress_cidrs must be canonical IPv4 /32 values') from exc
        if interface.version != 4 or interface.network.prefixlen != 32 or str(interface) != cidr:
            raise ValueError('debug_access.ssh_ingress_cidrs must be canonical IPv4 /32 values')
    return cidrs


def validate_observation_windows(desktop_window, node_window):
    node_window = str(node_window)
    if desktop_window not in DESKTOP_WINDOWS or node_window not in NODE_WINDOWS | {'auto'}:
        raise ValueError('desktop window must be 0, 10, or 20; node window must be auto, 0, 10, 20, or until-expiry')
    if desktop_window and node_window not in {'0', 'auto'}:
        raise ValueError('desktop and node observation windows are mutually exclusive')


def resolve_node_observation(spec, requested, mode, desktop_window=0):
    """Resolve the node window from the reviewed declaration without renewal."""
    if requested not in NODE_WINDOWS | {'auto'}:
        raise ValueError('node_observation_window_minutes must be auto, 0, 10, 20, or until-expiry')
    if mode != 'apply' or desktop_window:
        return '0'
    observation = spec.get('node_observation')
    declared_until = (
        isinstance(observation, dict)
        and observation.get('mode') == 'until-expiry'
        and observation.get('release_on_failure') is True
    )
    if spec.get('ttl_minutes') != 60 or not declared_until:
        raise ValueError('apply requires the reviewed 60-minute until-expiry declaration with release_on_failure=true')
    if requested == 'auto':
        return 'until-expiry' if declared_until else '0'
    if requested == '0':
        return '0'
    return requested


def _exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f'public desktop handoff has an invalid {label} allowlist')


def validate_public_handoff(value):
    """Validate the intentionally public, non-credential desktop handoff."""
    _exact_keys(value, PUBLIC_HANDOFF_KEYS, 'top-level')
    run = value['run']
    if not isinstance(run, str) or not re.fullmatch(r'xcl-[0-9]+-[0-9]+', run):
        raise ValueError('public desktop handoff has an invalid run')
    try:
        expires = datetime.datetime.fromisoformat(value['expires_at'].replace('Z', '+00:00'))
    except (AttributeError, ValueError) as exc:
        raise ValueError('public desktop handoff has an invalid expiry') from exc
    if expires.tzinfo is None:
        raise ValueError('public desktop handoff expiry must include a timezone')
    if not all(isinstance(value[key], str) and value[key] for key in ('network_id', 'gateway_id')):
        raise ValueError('public desktop handoff identity fields are required')
    if not re.fullmatch(rf'net_[a-z0-9][a-z0-9_-]*-{re.escape(run)}', value['network_id']):
        raise ValueError('public desktop handoff network identity is not run-bound')
    if value['gateway_id'] != f'gw-{run}':
        raise ValueError('public desktop handoff Gateway identity is not run-bound')
    try:
        gateway_key = base64.b64decode(value['gateway_public_key'], validate=True)
    except Exception as exc:
        raise ValueError('public desktop handoff has an invalid Gateway public key') from exc
    if len(gateway_key) != 32:
        raise ValueError('public desktop handoff has an invalid Gateway public key')
    _exact_keys(value['gateway_endpoint'], PUBLIC_ENDPOINT_KEYS, 'Gateway endpoint')
    endpoint = value['gateway_endpoint']
    try:
        endpoint_ip = ipaddress.ip_address(endpoint['host'])
    except ValueError as exc:
        raise ValueError('public desktop handoff Gateway endpoint must be IPv4') from exc
    if endpoint_ip.version != 4 or endpoint['port'] != 443 or endpoint['server_name'] != 'xconnect-lab.invalid':
        raise ValueError('public desktop handoff Gateway endpoint is invalid')
    if value['accounts_url'] != FORMAL_ACCOUNTS_URL or value['portal_url'] != FORMAL_PORTAL_URL:
        raise ValueError('public desktop handoff URLs must use the formal UAT endpoints')
    _exact_keys(value['instances'], PUBLIC_INSTANCE_GROUP_KEYS, 'instance groups')
    for group in PUBLIC_INSTANCE_GROUP_KEYS:
        _exact_keys(value['instances'][group], PUBLIC_INSTANCE_KEYS, f'{group} instance')
        instance = value['instances'][group]
        if not all(isinstance(instance[key], str) and instance[key] for key in PUBLIC_INSTANCE_KEYS):
            raise ValueError('public desktop handoff instance fields are required')
        if not re.fullmatch(r'i-[0-9a-f]+', instance['instance_id']):
            raise ValueError('public desktop handoff has an invalid instance ID')
        try:
            public_ip = ipaddress.ip_address(instance['public_ip'])
            private_ip = ipaddress.ip_address(instance['private_ip'])
        except ValueError as exc:
            raise ValueError('public desktop handoff instance addresses must be IPs') from exc
        if public_ip.version != 4 or private_ip.version != 4 or not private_ip.is_private:
            raise ValueError('public desktop handoff instance addresses must be IPv4 with a private address')
    if value['gateway_endpoint']['host'] not in {
        value['instances']['gateway']['public_ip'], value['instances']['gateway']['private_ip'],
    }:
        raise ValueError('public handoff endpoint is not bound to the Gateway address')
    _exact_keys(value['expected_device_ids'], PUBLIC_EXPECTED_DEVICE_KEYS, 'expected device IDs')
    if value['expected_device_ids'] != {
        'darwin': f'one-darwin-{run}', 'windows': f'one-windows-{run}',
    }:
        raise ValueError('public desktop handoff expected device IDs are not run-bound')
    _exact_keys(value['verification'], PUBLIC_VERIFICATION_KEYS, 'verification')
    if value['verification'] != {'target': 'http://10.77.0.1:8080/', 'expected_marker': run}:
        raise ValueError('public desktop handoff verification binding is invalid')
    forbidden = ('invite', 'token', 'vless', 'private', 'owneremail', 'owner_email')
    if any(any(word in str(key).lower() for word in forbidden) for key in value):
        raise ValueError('public desktop handoff contains a forbidden field')
    return True


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == 'validate-desktop':
        if len(sys.argv) != 4:
            raise ValueError('validate-desktop requires a declaration and window')
        declaration = json.loads(Path(sys.argv[2]).read_text())
        validate_desktop_validation(declaration['spec'], int(sys.argv[3]))
        return
    if len(sys.argv) >= 2 and sys.argv[1] == 'validate-transport':
        if len(sys.argv) != 4:
            raise ValueError('validate-transport requires a declaration and comma-separated ingress list')
        declaration = json.loads(Path(sys.argv[2]).read_text())
        validate_gateway_transport_ingress(declaration['spec'], sys.argv[3])
        return
    if len(sys.argv) >= 2 and sys.argv[1] == 'validate-windows':
        if len(sys.argv) != 4:
            raise ValueError('validate-windows requires desktop and node windows')
        validate_observation_windows(int(sys.argv[2]), sys.argv[3])
        return
    if len(sys.argv) >= 2 and sys.argv[1] == 'resolve-node-observation':
        if len(sys.argv) != 6:
            raise ValueError('resolve-node-observation requires declaration, requested window, mode, and desktop window')
        declaration = json.loads(Path(sys.argv[2]).read_text())
        print(resolve_node_observation(declaration['spec'], sys.argv[3], sys.argv[4], int(sys.argv[5])))
        return
    if len(sys.argv) >= 2 and sys.argv[1] == 'validate-handoff':
        if len(sys.argv) != 3:
            raise ValueError('validate-handoff requires a JSON path')
        validate_public_handoff(json.loads(Path(sys.argv[2]).read_text()))
        return
    action, directory, declaration = sys.argv[1:]
    folder = Path(directory)
    spec = json.loads(Path(declaration).read_text())['spec']
    run = os.environ['TF_VAR_run_id']
    gateway_provider = os.environ.get('GATEWAY_PROVIDER', spec['gateway_provider']).strip()
    if gateway_provider not in {'aws-spot', 'external'}:
        raise ValueError('GATEWAY_PROVIDER must be aws-spot or external')
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
        desktop_window = int(os.environ.get('DESKTOP_JOIN_WINDOW_MINUTES', '0'))
        desktop_ingress_cidrs = validate_gateway_transport_ingress(
            spec, os.environ.get('GATEWAY_TRANSPORT_INGRESS_CIDRS'))
        if desktop_window:
            desktop_ingress_cidrs = validate_desktop_validation(spec, desktop_window)
        ssh_debug_ingress_cidrs = validate_ssh_debug_access(
            spec, os.environ.get('SSH_DEBUG_INGRESS_CIDRS'))
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
                      gateway_transport_ingress_cidrs=desktop_ingress_cidrs,
                      ssh_debug_ingress_cidrs=ssh_debug_ingress_cidrs,
                      expires_at=(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=spec['ttl_minutes'])).strftime('%Y-%m-%dT%H:%M:%SZ'))
        if gateway_provider == 'external':
            external_ip = os.environ.get('EXTERNAL_GATEWAY_HOST', '').strip()
            try:
                parsed_external_ip = ipaddress.ip_address(external_ip)
            except ValueError as exc:
                raise ValueError('EXTERNAL_GATEWAY_HOST must be an IPv4 address') from exc
            if parsed_external_ip.version != 4:
                raise ValueError('EXTERNAL_GATEWAY_HOST must be an IPv4 address')
            values['external_gateway_ip'] = external_ip
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
                      ssh_public_key='unused-for-destroy', gateway_transport_ingress_cidrs=[],
                      ssh_debug_ingress_cidrs=[],
                      expires_at='1970-01-01T00:00:00Z')
        if gateway_provider == 'external':
            values['external_gateway_ip'] = os.environ.get('EXTERNAL_GATEWAY_HOST', '127.0.0.1')
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
