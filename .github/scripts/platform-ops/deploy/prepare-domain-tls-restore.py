#!/usr/bin/env python3
"""Vault/OIDC boundary only: prepare protected vars for the pinned PEM Role."""
import base64
import json
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen


def request(url, headers=None, body=None):
    payload = None if body is None else json.dumps(body).encode()
    req = Request(url, data=payload, headers=headers or {})
    with urlopen(req, timeout=30) as response:
        return json.load(response)


def material_vars(record, environment):
    target = environment['MATRIX_HOST']
    directory = environment['DOMAIN_TLS_DIR']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', target):
        raise ValueError('exact host required')
    if not re.fullmatch(r'/etc/xcontrol/tls/[A-Za-z0-9][A-Za-z0-9_.-]*', directory):
        raise ValueError('approved domain directory required')
    margin = int(environment.get('CADDY_CERT_RENEW_MARGIN_DAYS', '14'))
    if margin < 0:
        raise ValueError('negative validity margin')
    fields = {'fullchain': 'tls_fullchain_pem_b64', 'cert': 'tls_cert_pem_b64',
              'key': 'tls_key_pem_b64', 'ca': 'tls_ca_pem_b64',
              'trust_bundle': 'tls_trust_bundle_pem_b64'}
    if not all(record.get(field) for field in fields.values()):
        return None, 'incomplete-backup'
    expiry = record.get('not_after_epoch')
    if expiry not in (None, '') and int(expiry) - time.time() < margin * 86400:
        return None, 'renewal-margin'
    material = {key: base64.b64decode(record[field], validate=True).decode()
                for key, field in fields.items()}
    return {'caddy_certificate_restore_target': target,
            'caddy_certificate_restore_directory': directory,
            'caddy_certificate_restore_min_validity_seconds': margin * 86400,
            'caddy_certificate_restore_material': material}, 'ready'


def output(values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as handle:
        for key, value in values.items():
            handle.write(f'{key}={value}\n')


def main():
    env = os.environ
    vault = env['VAULT_ADDR'].rstrip('/')
    path = env['VAULT_CADDY_PATH']
    # Preserve the current managed Vault workflow identity and record path.
    if not path.startswith('kv/data/') or '..' in path.split('/'):
        raise ValueError('unsafe Vault record path')
    split = urlsplit(env['ACTIONS_ID_TOKEN_REQUEST_URL'])
    query = dict(parse_qsl(split.query))
    query['audience'] = 'vault'
    oidc_url = urlunsplit((split.scheme, split.netloc, split.path, urlencode(query), split.fragment))
    jwt = request(oidc_url, {'Authorization': 'bearer ' + env['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})['value']
    token = request(vault + '/v1/auth/jwt/login', {'Content-Type': 'application/json'},
                    {'role': env['VAULT_ROLE'], 'jwt': jwt})['auth']['client_token']
    headers = {'X-Vault-Token': token, 'Content-Type': 'application/json'}
    runtime_file = None
    delivered = False
    try:
        try:
            record = request(vault + '/v1/' + path, headers)['data']['data']
        except HTTPError as error:
            if error.code != 404:
                raise
            output({'restore_required': 'false', 'reason': 'no-backup'})
            return
        variables, reason = material_vars(record, env)
        if variables is None:
            output({'restore_required': 'false', 'reason': reason})
            return
        fd, filename = tempfile.mkstemp(prefix='domain-tls-', suffix='.json', dir=env['RUNNER_TEMP'])
        runtime_file = Path(filename)
        with os.fdopen(fd, 'w') as handle:
            json.dump(variables, handle)
        output({'restore_required': 'true', 'vars_file': str(runtime_file), 'reason': 'ready'})
        delivered = True
    finally:
        if runtime_file is not None and not delivered:
            runtime_file.unlink(missing_ok=True)
        # A failure to revoke is a failing security gate, not a silent success.
        req = Request(vault + '/v1/auth/token/revoke-self', data=b'{}', headers=headers, method='POST')
        try:
            with urlopen(req, timeout=30):
                pass
        except Exception:
            if runtime_file is not None:
                runtime_file.unlink(missing_ok=True)
            raise


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Never expose HTTP response bodies, JWTs, tokens or PEM material.
        print('::error::TLS preparation failed at the Vault/input boundary; refusing restoration.')
        raise SystemExit(1)
